#!/usr/bin/env bash
sudo bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive
# tar/gzip are on every Ubuntu, but a minimal cloud image can be missing the ssh
# CLIENT (openssh-server is not the same package), and a remote destination is
# useless without it. Install quietly rather than failing later mid-backup.
command -v ssh >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq openssh-client >/dev/null 2>&1 || true; }

mkdir -p /etc/backup-wizard /var/lib/backup-wizard
chmod 700 /etc/backup-wizard

cat > /usr/local/sbin/backup-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

CFGDIR=/etc/backup-wizard
CFG="$CFGDIR/config"
SRCLIST="$CFGDIR/sources.list"
EXLIST="$CFGDIR/excludes.list"
STATEDIR=/var/lib/backup-wizard
LOG=/var/log/backup-wizard.log
LOCAL_BK=/var/backups/backup-wizard          # pre-restore safety archives live here
SVC_UNIT=/etc/systemd/system/backup-wizard.service
TMR_UNIT=/etc/systemd/system/backup-wizard.timer
CRON_FILE=/etc/cron.d/backup-wizard

mkdir -p "$CFGDIR" "$STATEDIR" "$LOCAL_BK"

# ---------------------------------------------------------------- defaults ---
# Written once, then owned by the operator. /var/cache and the container stores
# are excluded because they are re-creatable bulk that can dwarf everything you
# actually care about; /proc, /sys, /dev and /run are kernel-generated and
# restoring them is meaningless (they only matter if someone adds "/" as a
# source, which the wizard allows).
if [ ! -f "$SRCLIST" ]; then
  cat > "$SRCLIST" <<'SRCDEF'
/etc
/root
/home
/opt
SRCDEF
fi
if [ ! -f "$EXLIST" ]; then
  cat > "$EXLIST" <<'EXDEF'
/proc
/sys
/dev
/run
/tmp
/var/tmp
/var/cache
/var/lib/docker
/var/lib/containerd
/var/lib/lxcfs
/swap.img
/swapfile
*/.cache/*
*/lost+found/*
*.sock
*/venv/*
*/.venv/*
*/node_modules/*
*/__pycache__/*
*.pyc
*/.pytest_cache/*
EXDEF
fi
[ -f "$CFG" ] || cat > "$CFG" <<'CFGDEF'
DEST_TYPE=
DEST_DIR=
DEST_HOST=
DEST_MUST_BE_MOUNT=no
RETENTION=7
CFGDEF
chmod 600 "$CFG"

DEST_TYPE=; DEST_DIR=; DEST_HOST=; DEST_MUST_BE_MOUNT=no; RETENTION=7
# shellcheck disable=SC1090
. "$CFG"

save_cfg() {
  cat > "$CFG" <<CFGW
DEST_TYPE=$DEST_TYPE
DEST_DIR=$DEST_DIR
DEST_HOST=$DEST_HOST
DEST_MUST_BE_MOUNT=$DEST_MUST_BE_MOUNT
RETENTION=$RETENTION
CFGW
  chmod 600 "$CFG"
}

# ----------------------------------------------------------------- helpers ---
hsize() { awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB PB",u," ");i=1;while(b>=1024&&i<6){b/=1024;i++};if(i==1)printf "%d %s",b,u[i];else printf "%.1f %s",b,u[i]}'; }
hage()  { awk -v s="${1:-0}" 'BEGIN{if(s<0)s=0; if(s<3600)printf "%dm ago",s/60; else if(s<86400)printf "%dh ago",s/3600; else printf "%dd ago",s/86400}'; }
now()   { date +%s; }
ts()    { date +%Y%m%d-%H%M%S; }
logline() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# read returns non-zero at EOF, which under set -e would end the whole wizard
# instead of just returning to the menu.
pause() { [ "$RUNMODE" = "auto" ] && return 0; echo; read -rp "  [Enter] to continue " _ || true; }

# The scheduled run and a human at the keyboard must never write into the same
# destination at the same time: two tars racing on one directory produce two
# half-archives and a wrong retention prune. Non-blocking, so the timer simply
# skips a run instead of stacking processes up behind a person who is thinking.
# The lock is taken around the WRITING actions only — holding it for a whole
# menu session would silently block every scheduled backup while someone reads.
try_lock() {
  exec 9>/run/backup-wizard.lock
  flock -n 9
}
# Closing the descriptor drops the lock. The menu calls this the moment a write
# finishes, so an operator who leaves the wizard open on the screen for an hour
# does not quietly suppress the nightly backup.
unlock() { exec 9>&- 2>/dev/null; return 0; }

mapfile -t SOURCES < <(grep -vE '^\s*(#|$)' "$SRCLIST" 2>/dev/null || true)
mapfile -t EXCLUDES < <(grep -vE '^\s*(#|$)' "$EXLIST" 2>/dev/null || true)

# mountpoint(1) is in util-linux on every supported release, but findmnt is the
# safer primary because it also reports bind mounts consistently.
is_mounted() {
  if command -v findmnt >/dev/null 2>&1; then findmnt -rn --target "$1" --mountpoint "$1" >/dev/null 2>&1
  elif command -v mountpoint >/dev/null 2>&1; then mountpoint -q "$1"
  else return 1; fi
}

dest_desc() {
  case "$DEST_TYPE" in
    local) echo "local dir  $DEST_DIR" ;;
    ssh)   echo "ssh        $DEST_HOST:$DEST_DIR" ;;
    *)     echo "(not configured)" ;;
  esac
}

dest_configured() { [ -n "$DEST_TYPE" ] && [ -n "$DEST_DIR" ]; }

# Every remote call is BatchMode: a scheduled backup that stops on a password
# prompt hangs forever holding the lock, and nobody sees it until the day they
# need a restore. If keys are not set up we want an immediate, visible failure.
rsh() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$DEST_HOST" "$@"; }

# ------------------------------------------------- destination abstraction ---
# One archive layout, two back-ends. Everything below (list/verify/restore/
# prune) goes through these five, so nothing else has to care where the files
# live.

dst_ready() {
  # Returns 0 when the destination is usable RIGHT NOW. Called before every
  # write, not only at config time.
  case "$DEST_TYPE" in
    local)
      # An SMB/SSHFS destination that failed to mount leaves an ordinary empty
      # directory behind. Writing there silently fills the SYSTEM disk with
      # backups that are not on the backup target at all — and the operator
      # only finds out when the root filesystem is full. If the path was a
      # mountpoint when it was configured, insist that it still is one.
      if [ "$DEST_MUST_BE_MOUNT" = "yes" ] && ! is_mounted "$DEST_DIR"; then
        echo "  ERROR: $DEST_DIR is configured as a MOUNTED destination but nothing is mounted there."
        echo "         Refusing to write backups onto the local disk under a dead mountpoint."
        echo "         Mount it, then retry (or reconfigure the destination in option 6)."
        return 1
      fi
      mkdir -p "$DEST_DIR" 2>/dev/null || { echo "  ERROR: cannot create $DEST_DIR"; return 1; }
      [ -w "$DEST_DIR" ] || { echo "  ERROR: $DEST_DIR is not writable"; return 1; }
      ;;
    ssh)
      if ! rsh "mkdir -p '$DEST_DIR' && test -w '$DEST_DIR'" >/dev/null 2>&1; then
        echo "  ERROR: cannot reach $DEST_HOST or $DEST_DIR is not writable there."
        echo "         Check the key login:  ssh -o BatchMode=yes $DEST_HOST true"
        return 1
      fi
      ;;
    *) echo "  ERROR: no destination configured (menu option 6)."; return 1 ;;
  esac
  return 0
}

dst_list() {
  # "epoch size name", newest first. .partial files are named with a leading dot
  # and a .partial suffix precisely so they can never be mistaken for a finished
  # backup by this listing.
  case "$DEST_TYPE" in
    local) find "$DEST_DIR" -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %s %f\n' 2>/dev/null | sort -rn || true ;;
    ssh)   rsh "find '$DEST_DIR' -maxdepth 1 -type f -name '*.tar.gz' -printf '%T@ %s %f\n' 2>/dev/null" 2>/dev/null | sort -rn || true ;;
  esac
}

dst_free() {
  # Bytes available at the destination, or empty when it cannot be measured.
  local out=""
  case "$DEST_TYPE" in
    local) out=$(df -P -B1 "$DEST_DIR" 2>/dev/null | awk 'NR==2{print $4}') || true ;;
    ssh)   out=$(rsh "df -P -B1 '$DEST_DIR'" 2>/dev/null | awk 'NR==2{print $4}') || true ;;
  esac
  echo "$out"
}

dst_cat() {
  case "$DEST_TYPE" in
    local) cat "$DEST_DIR/$1" ;;
    ssh)   rsh "cat '$DEST_DIR/$1'" ;;
  esac
}

dst_exists() {
  case "$DEST_TYPE" in
    local) [ -e "$DEST_DIR/$1" ] ;;
    ssh)   rsh "test -e '$DEST_DIR/$1'" >/dev/null 2>&1 ;;
    *)     return 1 ;;
  esac
}

dst_rm() {
  case "$DEST_TYPE" in
    local) rm -f "$DEST_DIR/$1" ;;
    ssh)   rsh "rm -f '$DEST_DIR/$1'" ;;
  esac
}

# ------------------------------------------------------------------- show ----
sched_state() {
  local s=""
  if systemctl list-unit-files 2>/dev/null | grep -q '^backup-wizard\.timer'; then
    # is-active PRINTS "inactive" and EXITS non-zero, so it needs both the
    # `|| true` (set -e would kill this function) and a variable test rather
    # than a `|| echo` fallback, which would append a second word.
    local a; a=$(systemctl is-active backup-wizard.timer 2>/dev/null) || true
    local oc; oc=$(grep -m1 '^OnCalendar=' "$TMR_UNIT" 2>/dev/null | cut -d= -f2-) || true
    s="systemd timer (${a:-unknown}) ${oc:-}"
  elif [ -f "$CRON_FILE" ]; then
    s="cron  $(grep -vE '^\s*(#|$)' "$CRON_FILE" 2>/dev/null | head -1 | awk '{print $1,$2,$3,$4,$5}')"
  else
    s="none"
  fi
  echo "$s"
}

show() {
  local free last n epoch size name lastres
  echo
  echo "======================================================================"
  echo " Backup & restore"
  echo "======================================================================"
  printf "  %-20s %s\n" "this host:" "$(hostname)"
  printf "  %-20s %s\n" "destination:" "$(dest_desc)"
  if dest_configured; then
    free=$(dst_free) || true
    printf "  %-20s %s\n" "free at dest:" "$([ -n "$free" ] && hsize "$free" || echo 'unknown (unreachable?)')"
    if [ "$DEST_TYPE" = "local" ]; then
      # A "backup" on the same filesystem as the data survives a mistake but not
      # a dead disk. Worth saying out loud every single time.
      local sd dd
      sd=$(df -P / 2>/dev/null | awk 'NR==2{print $1}') || true
      dd=$(df -P "$DEST_DIR" 2>/dev/null | awk 'NR==2{print $1}') || true
      [ -n "$sd" ] && [ "$sd" = "$dd" ] && printf "  %-20s %s\n" "" "WARNING: same filesystem as / — will not survive a disk failure"
    fi
  fi
  printf "  %-20s %s\n" "sources:" "${SOURCES[*]:-(none)}"
  printf "  %-20s %s\n" "excludes:" "${#EXCLUDES[@]} pattern(s)"
  printf "  %-20s %s\n" "retention:" "keep newest $RETENTION"
  printf "  %-20s %s\n" "schedule:" "$(sched_state)"

  if dest_configured; then
    n=0; last=""
    while read -r epoch size name; do
      [ -z "$name" ] && continue
      n=$((n+1)); [ -z "$last" ] && last="$epoch $size $name"
    done < <(dst_list)
    if [ -n "$last" ]; then
      set -- $last
      printf "  %-20s %s  (%s, %s)\n" "latest backup:" "$3" "$(hsize "$2")" "$(hage $(( $(now) - ${1%%.*} )))"
    else
      printf "  %-20s %s\n" "latest backup:" "(none found)"
    fi
    printf "  %-20s %s\n" "backups held:" "$n"
  fi
  lastres=$(cat "$STATEDIR/last-result" 2>/dev/null) || true
  [ -n "$lastres" ] && printf "  %-20s %s\n" "last run:" "$lastres"
  echo "----------------------------------------------------------------------"
}

# ------------------------------------------------------- exclude/tar setup ---
build_ex_args() {
  # Fills TAR_EX and DU_EX. Both tools take --exclude=PATTERN, so one loop does.
  TAR_EX=(); DU_EX=()
  local p
  for p in "${EXCLUDES[@]}"; do
    TAR_EX+=("--exclude=$p")
    DU_EX+=("--exclude=$p")
  done
  # THE classic own-goal: the destination sits inside a source (say /opt/backups
  # while /opt is backed up), so tar reads the archive it is currently writing
  # and the file grows until the disk is full. Always exclude the destination,
  # whether or not it looks nested — it costs nothing when it is elsewhere.
  if [ "$DEST_TYPE" = "local" ] && [ -n "$DEST_DIR" ]; then
    local rp; rp=$(realpath -m "$DEST_DIR" 2>/dev/null) || rp="$DEST_DIR"
    TAR_EX+=("--exclude=$rp" "--exclude=$rp/*")
    DU_EX+=("--exclude=$rp")
  fi
  TAR_EX+=("--exclude=$LOCAL_BK" "--exclude=$LOCAL_BK/*")
  DU_EX+=("--exclude=$LOCAL_BK")
}

existing_sources() {
  # tar exits 2 on a missing path and writes nothing useful, so drop absent
  # sources here and say which ones went, instead of failing the whole run.
  LIVE=()
  local s
  for s in "${SOURCES[@]}"; do
    if [ -e "$s" ]; then LIVE+=("$s"); else echo "  skipping missing source: $s"; fi
  done
}

# ----------------------------------------------------------------- backup ----
do_backup() {
  dest_configured || { echo "  No destination configured — use option 6 first."; return 1; }
  if ! try_lock; then
    echo "  Another backup-wizard run is already writing — not starting a second one."
    logline "SKIP: lock held"
    return 1
  fi
  dst_ready || return 1

  existing_sources
  [ "${#LIVE[@]}" -eq 0 ] && { echo "  Nothing to back up (no source path exists)."; return 1; }
  build_ex_args

  local name part est free base n=1
  base="$(hostname -s 2>/dev/null || hostname)-$(ts)"
  name="$base.tar.gz"
  # Two runs inside the same second (a manual backup racing the timer, or a
  # quick retry) would otherwise write the same filename and the second would
  # silently replace the first — one archive where the operator counts two.
  while dst_exists "$name"; do n=$((n+1)); name="$base-$n.tar.gz"; done
  part=".${name}.partial"

  echo
  echo "  Sources : ${LIVE[*]}"
  echo "  Dest    : $(dest_desc)"
  echo "  Archive : $name"
  echo "  Measuring size (this can take a minute on a big tree)..."
  # du exits non-zero on any unreadable directory while still printing the
  # totals it did compute — under set -e that status would end the function, so
  # the substitution must be allowed to fail.
  est=$(du -sb "${DU_EX[@]}" "${LIVE[@]}" 2>/dev/null | awk '{s+=$1} END{printf "%d", s+0}') || true
  est=${est:-0}
  free=$(dst_free) || true
  printf "  Uncompressed source data: %s\n" "$(hsize "$est")"
  printf "  Free at destination     : %s\n" "$([ -n "$free" ] && hsize "$free" || echo unknown)"

  # An estimate of zero means every source matched an exclude pattern (easy to
  # do: an exclude of /tmp swallows a source under /tmp). tar would happily
  # write a valid, empty archive and report success — a backup of nothing that
  # looks exactly like a good one in the listing.
  if [ "$est" -eq 0 ]; then
    echo
    echo "  WARNING: the sources measure 0 bytes after excludes — this archive would be EMPTY."
    echo "           Check the source paths and $EXLIST."
    if [ "$RUNMODE" = "auto" ]; then
      logline "ABORT: sources measure 0 bytes after excludes"
      return 1
    fi
    read -rp "  Continue anyway? [y/N]: " GOE
    [ "$GOE" = "y" ] || [ "$GOE" = "Y" ] || { echo "  Aborted."; return 1; }
  fi

  if [ -n "$free" ] && [ "$est" -gt 0 ] && [ "$free" -lt "$est" ]; then
    echo
    echo "  REFUSING: the destination has less free space than the data being archived."
    echo "  gzip usually gets 2-3x on system files, so this MAY still fit — but a"
    echo "  backup that dies at 99% is worse than one you never started."
    if [ "$RUNMODE" = "auto" ]; then
      logline "ABORT: insufficient space at destination (est $est, free $free)"
      return 1
    fi
    read -rp "  Try anyway? [y/N]: " GO
    [ "$GO" = "y" ] || [ "$GO" = "Y" ] || { echo "  Aborted."; return 1; }
  fi

  echo "  Working..."
  local rc=0 t0 t1
  t0=$(now)
  # tar's exit codes matter here: 0 = fine, 1 = "some file changed while being
  # read" (normal on a live system — the archive is still valid), 2 = a real
  # failure. set -e is lifted around it so the 1 case does not kill the run.
  set +e
  if [ "$DEST_TYPE" = "local" ]; then
    tar -czf "$DEST_DIR/$part" "${TAR_EX[@]}" "${LIVE[@]}" 2>"$STATEDIR/tar.err"
    rc=$?
  else
    # Stream straight to the far end — no local staging copy, so this works on a
    # box with no spare disk. PIPESTATUS must be read on the very next line.
    tar -czf - "${TAR_EX[@]}" "${LIVE[@]}" 2>"$STATEDIR/tar.err" | rsh "cat > '$DEST_DIR/$part'"
    local ps=("${PIPESTATUS[@]}")
    rc=${ps[0]}
    [ "${ps[1]}" -ne 0 ] && rc=2      # the transfer failed: the archive is junk
  fi
  set -e
  t1=$(now)

  if [ "$rc" -ge 2 ]; then
    echo "  FAILED (tar/transfer exit $rc):"
    sed 's/^/    /' "$STATEDIR/tar.err" 2>/dev/null | tail -10
    # Never leave a truncated file that looks like a backup.
    dst_rm "$part"
    echo "  Partial archive removed."
    echo "FAILED $(date '+%F %H:%M') — see $LOG" > "$STATEDIR/last-result"
    logline "FAILED rc=$rc archive=$name"
    return 1
  fi
  [ "$rc" -eq 1 ] && echo "  (note: some files changed while being read — normal on a live system)"

  # Only now does it become a real backup: the rename is the commit.
  case "$DEST_TYPE" in
    local) mv "$DEST_DIR/$part" "$DEST_DIR/$name" ;;
    ssh)   rsh "mv '$DEST_DIR/$part' '$DEST_DIR/$name'" ;;
  esac

  local sz=""
  # A while loop returns the status of the LAST command in its body, so a bare
  # `[ ... ] && sz=$s` that fails on the final iteration would trip set -e.
  while read -r _e s n; do
    if [ "$n" = "$name" ]; then sz="$s"; fi
  done < <(dst_list)
  echo "  DONE  $name  $( [ -n "$sz" ] && hsize "$sz" )  in $((t1-t0))s"
  echo "OK $(date '+%F %H:%M') $name $( [ -n "$sz" ] && hsize "$sz" )" > "$STATEDIR/last-result"
  logline "OK archive=$name bytes=${sz:-?} secs=$((t1-t0))"

  prune_old
}

prune_old() {
  # Retention is deliberately a COUNT, not an age: a box that was off for a
  # month must not wake up and delete its only copies.
  [ -z "$RETENTION" ] && return 0
  [ "$RETENTION" -le 0 ] 2>/dev/null && return 0
  local n=0 epoch size name
  while read -r epoch size name; do
    [ -z "$name" ] && continue
    n=$((n+1))
    [ "$n" -le "$RETENTION" ] && continue
    echo "  pruning old backup: $name ($(hsize "$size"))"
    logline "PRUNE $name"
    # A failed delete (dest gone read-only, ssh dropped) must not abort the run:
    # the backup itself already succeeded, which is what matters.
    dst_rm "$name" || echo "  (could not delete $name)"
  done < <(dst_list)
}

# ------------------------------------------------------------------ list -----
list_backups() {
  dest_configured || { echo "  No destination configured — use option 6 first."; return 0; }
  local n=0 epoch size name total=0
  echo
  printf "  %-3s %-38s %12s  %s\n" "#" "ARCHIVE" "SIZE" "AGE"
  echo "  --------------------------------------------------------------------"
  while read -r epoch size name; do
    [ -z "$name" ] && continue
    n=$((n+1)); total=$((total+size))
    printf "  %-3s %-38s %12s  %s\n" "$n" "$name" "$(hsize "$size")" "$(hage $(( $(now) - ${epoch%%.*} )))"
  done < <(dst_list)
  echo "  --------------------------------------------------------------------"
  if [ "$n" -eq 0 ]; then
    echo "  No backups found at $(dest_desc)"
  else
    printf "  %d archive(s), %s total\n" "$n" "$(hsize "$total")"
  fi
}

# Shared picker: prints the chosen archive name on stdout, everything else on
# stderr so callers can capture it cleanly.
pick_backup() {
  local n=0 epoch size name
  ARCHIVES=()
  while read -r epoch size name; do
    [ -z "$name" ] && continue
    n=$((n+1)); ARCHIVES+=("$name")
    printf "  %-3s %-38s %12s  %s\n" "$n" "$name" "$(hsize "$size")" "$(hage $(( $(now) - ${epoch%%.*} )))" >&2
  done < <(dst_list)
  [ "$n" -eq 0 ] && { echo "  No backups at the destination." >&2; return 1; }
  local pick
  read -rp "  Number (Enter to cancel): " pick </dev/tty
  [ -z "$pick" ] && return 1
  case "$pick" in *[!0-9]*) echo "  Not a number." >&2; return 1 ;; esac
  # Written as an explicit if: `A || B && C` groups as ((A||B))&&C, which is a
  # standing trap in this repo even when it happens to be what you meant.
  if [ "$pick" -lt 1 ] || [ "$pick" -gt "$n" ]; then
    echo "  Out of range." >&2; return 1
  fi
  echo "${ARCHIVES[$((pick-1))]}"
}

# ---------------------------------------------------------------- verify -----
verify_backup() {
  dest_configured || { echo "  No destination configured."; return 0; }
  echo
  echo "  Pick an archive to verify:"
  local name; name=$(pick_backup) || return 0
  echo
  echo "  Reading $name end to end..."
  # tar -t decompresses the WHOLE stream, so gzip's CRC covers every byte: if
  # this passes, the archive is readable and intact, not merely present.
  local rc entries
  # PIPESTATUS is useless here: the pipeline runs inside a command substitution,
  # so the array would describe the assignment, not the tar. pipefail makes the
  # substitution itself fail when any stage of the inner pipeline failed.
  set +e
  set -o pipefail
  entries=$(dst_cat "$name" | tar -tzf - 2>"$STATEDIR/verify.err" | wc -l)
  rc=$?
  set +o pipefail
  set -e
  if [ "$rc" -eq 0 ]; then
    printf "  OK — %s entries, archive is readable end to end.\n" "$entries"
    logline "VERIFY OK $name entries=$entries"
  else
    echo "  CORRUPT / UNREADABLE — do not rely on this archive:"
    sed 's/^/    /' "$STATEDIR/verify.err" 2>/dev/null | tail -10
    logline "VERIFY FAILED $name"
  fi
}

# --------------------------------------------------------------- restore -----
restore_backup() {
  dest_configured || { echo "  No destination configured."; return 0; }
  # A scheduled backup starting halfway through an in-place restore would
  # archive a half-restored system and then prune a good copy to make room.
  if ! try_lock; then
    echo "  A backup is running right now — wait for it to finish before restoring."
    return 0
  fi
  echo
  echo "  Pick an archive to restore:"
  local name; name=$(pick_backup) || return 0
  local asize=""
  while read -r _e s n; do
    if [ "$n" = "$name" ]; then asize="$s"; fi
  done < <(dst_list)

  echo
  echo "  Contents of $name (first 30 entries):"
  # tar dies of SIGPIPE when head closes the pipe; that is expected, and the
  # pipeline status comes from head, so nothing to guard here.
  dst_cat "$name" 2>/dev/null | tar -tzf - 2>/dev/null | head -30 | sed 's/^/    /' || true
  echo "    ..."
  echo
  echo "  Top-level paths in this archive:"
  local tops; tops=$(dst_cat "$name" 2>/dev/null | tar -tzf - 2>/dev/null | awk -F/ 'NF>1{print $1}' | sort -u | head -20) || true
  echo "$tops" | sed 's|^|    /|'
  echo
  echo "  1) Extract to a STAGING directory  (safe — nothing live is touched)"
  echo "  2) Restore IN PLACE over the running system  (dangerous)"
  echo "  Enter) cancel"
  local mode; read -rp "  Choice: " mode
  case "$mode" in
    1) ;;
    2) ;;
    *) echo "  Cancelled."; return 0 ;;
  esac

  local CONFIRM
  read -rp "  Type RESTORE to continue: " CONFIRM
  [ "$CONFIRM" = "RESTORE" ] || { echo "  Not confirmed — nothing done."; return 0; }

  if [ "$mode" = "1" ]; then
    local stage="/var/restore/${name%.tar.gz}-$(ts)"
    read -rp "  Staging directory [$stage]: " ANS
    stage="${ANS:-$stage}"
    mkdir -p "$stage"
    # A 2 GB .tar.gz can be 6 GB extracted; filling the root filesystem during a
    # restore is a second outage on top of the first one.
    local sfree; sfree=$(df -P -B1 "$stage" 2>/dev/null | awk 'NR==2{print $4}') || true
    if [ -n "$sfree" ] && [ -n "$asize" ] && [ "$sfree" -lt $((asize*3)) ]; then
      echo "  WARNING: only $(hsize "$sfree") free here; extracted size is typically ~3x the"
      echo "           $(hsize "$asize") archive. Free some space or pick another directory."
      read -rp "  Continue anyway? [y/N]: " GO
      [ "$GO" = "y" ] || [ "$GO" = "Y" ] || { echo "  Aborted."; return 0; }
    fi
    echo "  Extracting to $stage ..."
    local ps
    set +e
    dst_cat "$name" | tar -xzpf - -C "$stage" 2>"$STATEDIR/restore.err"
    ps=("${PIPESTATUS[@]}")
    set -e
    if [ "$(( ${ps[0]} + ${ps[1]} ))" -eq 0 ]; then
      echo "  DONE. Files are under $stage (nothing live was modified)."
      echo "  Copy back what you need, e.g.:  cp -a $stage/etc/nginx /etc/"
      logline "RESTORE staged $name -> $stage"
    else
      echo "  FAILED:"; sed 's/^/    /' "$STATEDIR/restore.err" 2>/dev/null | tail -10
      logline "RESTORE FAILED (staging) $name"
    fi
    return 0
  fi

  # ---- in place ----
  echo
  echo "  ####################################################################"
  echo "  #  IN-PLACE RESTORE                                                #"
  echo "  #  Every file in the archive OVERWRITES the live copy, including   #"
  echo "  #  /etc. Config for services installed since the backup, and any   #"
  echo "  #  change made since then, is lost. Users, ssh keys and network    #"
  echo "  #  config revert to the state of the archive — you can lock        #"
  echo "  #  yourself out of this box. Files created after the backup are    #"
  echo "  #  NOT deleted; this is an overwrite, not a wipe.                  #"
  echo "  ####################################################################"
  echo
  # Refuse to overwrite the live system with an archive we have not proven is
  # readable: a half-extracted /etc from a corrupt tarball is the worst of both
  # worlds. This is a full decompression pass, so it takes a moment.
  echo "  Verifying the archive before touching anything (required)..."
  local vrc vps
  set +e
  dst_cat "$name" | tar -tzf - >/dev/null 2>"$STATEDIR/verify.err"
  vps=("${PIPESTATUS[@]}")
  set -e
  vrc=$(( ${vps[0]} + ${vps[1]} ))
  if [ "$vrc" -ne 0 ]; then
    echo "  REFUSING: this archive does not read cleanly. Verify (option 5) and pick another."
    sed 's/^/    /' "$STATEDIR/verify.err" 2>/dev/null | tail -5
    return 0
  fi
  echo "  Archive is readable."

  # Timestamped safety copy of exactly the paths about to be overwritten, so an
  # in-place restore is itself undoable.
  local pre="$LOCAL_BK/pre-restore-$(ts).tar.gz"
  local -a TOPPATHS=()
  local t
  while read -r t; do
    if [ -n "$t" ] && [ -e "/$t" ]; then TOPPATHS+=("/$t"); fi
  done <<< "$tops"
  if [ "${#TOPPATHS[@]}" -gt 0 ]; then
    read -rp "  Snapshot the current ${TOPPATHS[*]} to $pre first? [Y/n]: " SNAP
    if [ "$SNAP" != "n" ] && [ "$SNAP" != "N" ]; then
      build_ex_args
      echo "  Snapshotting (this can take a while)..."
      set +e
      tar -czf "$pre" "${TAR_EX[@]}" "${TOPPATHS[@]}" 2>/dev/null
      local prc=$?
      set -e
      if [ "$prc" -ge 2 ]; then
        rm -f "$pre"
        echo "  Snapshot FAILED — refusing to continue with an unprotected in-place restore."
        return 0
      fi
      echo "  Snapshot saved: $pre"
      logline "PRE-RESTORE snapshot $pre"
    fi
  fi

  echo
  read -rp "  Type IN-PLACE (exactly) to overwrite the live system: " C2
  [ "$C2" = "IN-PLACE" ] || { echo "  Not confirmed — nothing done."; return 0; }

  echo "  Restoring over / ..."
  # tar stored the members with the leading slash stripped, so extracting with
  # -C / puts every file back exactly where it came from.
  local rps
  set +e
  dst_cat "$name" | tar -xzpf - -C / 2>"$STATEDIR/restore.err"
  rps=("${PIPESTATUS[@]}")
  set -e
  if [ "$(( ${rps[0]} + ${rps[1]} ))" -eq 0 ]; then
    echo "  DONE — files restored in place."
    logline "RESTORE in-place $name"
  else
    echo "  Restore reported errors:"; sed 's/^/    /' "$STATEDIR/restore.err" 2>/dev/null | tail -10
    [ -f "$pre" ] && echo "  Your pre-restore snapshot is $pre"
    logline "RESTORE in-place ERRORS $name"
  fi
  echo
  echo "  Now: check the services you care about BEFORE rebooting —"
  echo "    systemctl --failed ; sshd -t ; journalctl -p err -n 30"
  echo "  A reboot with a broken /etc is how a remote box stops coming back."
}

# -------------------------------------------------------------- scheduling ---
have_systemd() { [ -d /run/systemd/system ]; }

remove_schedule() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^backup-wizard\.timer'; then
    systemctl disable --now backup-wizard.timer >/dev/null 2>&1 || true
    rm -f "$TMR_UNIT" "$SVC_UNIT"
    systemctl daemon-reload
    echo "  systemd timer removed."
  fi
  if [ -f "$CRON_FILE" ]; then rm -f "$CRON_FILE"; echo "  cron entry removed."; fi
}

schedule_menu() {
  dest_configured || { echo "  Configure a destination first (option 6) — a schedule with no destination just fails nightly."; return 0; }
  echo
  echo "  Current schedule: $(sched_state)"
  echo
  echo "  1) Daily at a chosen hour"
  echo "  2) Weekly on a chosen day/hour"
  echo "  3) Remove the schedule"
  echo "  Enter) back"
  local ch; read -rp "  Choice: " ch
  case "$ch" in
    1|2) ;;
    3) remove_schedule; return 0 ;;
    *) return 0 ;;
  esac

  local hour day oncal cronline
  read -rp "  Hour of day (0-23) [3]: " hour; hour="${hour:-3}"
  case "$hour" in *[!0-9]*|'') echo "  Not a number."; return 0 ;; esac
  [ "$hour" -gt 23 ] && { echo "  Hour must be 0-23."; return 0; }

  if [ "$ch" = "1" ]; then
    oncal="*-*-* $(printf '%02d' "$hour"):00:00"
    cronline="0 $hour * * *"
  else
    echo "  Day: 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat 7=Sun"
    read -rp "  Day [7]: " day; day="${day:-7}"
    case "$day" in [1-7]) ;; *) echo "  Pick 1-7."; return 0 ;; esac
    local names=(Mon Tue Wed Thu Fri Sat Sun)
    oncal="${names[$((day-1))]} *-*-* $(printf '%02d' "$hour"):00:00"
    cronline="0 $hour * * $((day % 7))"     # cron: 0=Sunday, so 7 wraps to 0
  fi

  read -rp "  Keep how many backups (retention) [$RETENTION]: " R
  R="${R:-$RETENTION}"
  case "$R" in *[!0-9]*|'') echo "  Not a number."; return 0 ;; esac
  [ "$R" -lt 1 ] && { echo "  Keep at least 1."; return 0; }
  RETENTION="$R"; save_cfg

  if have_systemd; then
    # Validate the calendar expression BEFORE writing a unit: a bad OnCalendar
    # leaves a timer that loads but never fires, and nothing complains.
    if ! systemd-analyze calendar "$oncal" >/dev/null 2>&1; then
      echo "  Refusing: systemd rejected the calendar expression '$oncal'."
      return 0
    fi
    cat > "$SVC_UNIT" <<SVCF
[Unit]
Description=Scheduled backup (backup-wizard)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup-wizard --run
Nice=10
IOSchedulingClass=idle
SVCF
    cat > "$TMR_UNIT" <<TMRF
[Unit]
Description=Scheduled backup timer (backup-wizard)

[Timer]
OnCalendar=$oncal
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
TMRF
    systemctl daemon-reload
    rm -f "$CRON_FILE"        # never leave both mechanisms running
    if systemctl enable --now backup-wizard.timer >/dev/null 2>&1; then
      echo "  Scheduled: $oncal (systemd timer, catches up after downtime)."
      systemctl list-timers backup-wizard.timer --no-pager 2>/dev/null | sed -n '1,2p' | sed 's/^/    /' || true
    else
      echo "  systemd refused the timer; falling back to cron."
      rm -f "$TMR_UNIT" "$SVC_UNIT"; systemctl daemon-reload
      printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s root /usr/local/sbin/backup-wizard --run >> %s 2>&1\n' "$cronline" "$LOG" > "$CRON_FILE"
      chmod 644 "$CRON_FILE"
      echo "  Scheduled via $CRON_FILE"
    fi
  else
    # /etc/cron.d needs the extra user field and a trailing newline, and it is
    # ignored outright if the filename contains a dot — hence "backup-wizard".
    printf 'SHELL=/bin/bash\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s root /usr/local/sbin/backup-wizard --run >> %s 2>&1\n' "$cronline" "$LOG" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    echo "  Scheduled via cron: $cronline  (no systemd on this box)"
  fi
  echo "  Retention: keep newest $RETENTION."
}

# ---------------------------------------------------------------- settings ---
edit_sources() {
  while :; do
    echo
    echo "  Source paths:"
    local i=0
    for i in "${!SOURCES[@]}"; do printf "    %-3s %s\n" "$((i+1))" "${SOURCES[$i]}"; done
    [ "${#SOURCES[@]}" -eq 0 ] && echo "    (none)"
    echo
    echo "    a) add a path   d) delete a path   Enter) done"
    local ch; read -rp "  Choice: " ch
    case "$ch" in
      a|A)
        read -rp "  Path to add: " P
        [ -z "$P" ] && continue
        [ -e "$P" ] || echo "  (note: $P does not exist right now — it will be skipped until it does)"
        if [ "$P" = "/" ]; then
          echo "  Backing up / pulls in every mounted filesystem, including network mounts"
          echo "  and USB disks. Only do this if you really mean a whole-system archive."
          read -rp "  Add / anyway? [y/N]: " Y
          [ "$Y" = "y" ] || [ "$Y" = "Y" ] || continue
        fi
        SOURCES+=("$P"); printf '%s\n' "${SOURCES[@]}" > "$SRCLIST"
        ;;
      d|D)
        read -rp "  Number to delete: " N
        case "$N" in *[!0-9]*|'') continue ;; esac
        if [ "$N" -lt 1 ] || [ "$N" -gt "${#SOURCES[@]}" ]; then echo "  Out of range."; continue; fi
        unset "SOURCES[$((N-1))]"
        SOURCES=("${SOURCES[@]}")     # reindex, or the array keeps a hole
        if [ "${#SOURCES[@]}" -eq 0 ]; then : > "$SRCLIST"; else printf '%s\n' "${SOURCES[@]}" > "$SRCLIST"; fi
        ;;
      *) return 0 ;;
    esac
  done
}

settings_menu() {
  echo
  echo "  1) Destination: local directory (including a mounted SMB/SSHFS path)"
  echo "  2) Destination: remote host over ssh"
  echo "  3) Source paths"
  echo "  4) Exclude patterns (opens \$EDITOR on $EXLIST)"
  echo "  5) Retention count"
  echo "  Enter) back"
  local ch; read -rp "  Choice: " ch
  case "$ch" in
    1)
      read -rp "  Directory [/backup]: " D; D="${D:-/backup}"
      # Single quotes are what wraps every remote path in this script; a quote
      # inside the path would break out of that quoting. Cheaper to refuse.
      case "$D" in *"'"*) echo "  Refusing a path containing a single quote."; return 0 ;; esac
      mkdir -p "$D" || { echo "  Cannot create $D"; return 0; }
      DEST_TYPE=local; DEST_DIR="$D"; DEST_HOST=
      if is_mounted "$D"; then
        DEST_MUST_BE_MOUNT=yes
        echo "  $D is a mountpoint — backups will REFUSE to run when it is not mounted."
      else
        DEST_MUST_BE_MOUNT=no
        # Common with SMB/SSHFS: they configure the target before mounting it.
        echo "  $D is a plain directory on this machine's own disk."
      fi
      save_cfg; echo "  Destination set: $(dest_desc)"
      ;;
    2)
      read -rp "  Remote (user@host): " H
      [ -z "$H" ] && return 0
      read -rp "  Remote directory [/backup]: " D; D="${D:-/backup}"
      case "$D$H" in *"'"*) echo "  Refusing a value containing a single quote."; return 0 ;; esac
      echo "  Testing key-based login (no password prompt allowed)..."
      if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$H" true >/dev/null 2>&1; then
        echo "  REFUSING: cannot log in to $H without a password."
        echo "  A scheduled backup cannot type a password — set up a key first:"
        echo "      ssh-keygen -t ed25519      (if you have no key)"
        echo "      ssh-copy-id $H"
        return 0
      fi
      DEST_TYPE=ssh; DEST_HOST="$H"; DEST_DIR="$D"; DEST_MUST_BE_MOUNT=no
      if ! ssh -o BatchMode=yes "$H" "mkdir -p '$D' && test -w '$D'" >/dev/null 2>&1; then
        echo "  REFUSING: $D on $H is not writable."
        DEST_TYPE=; DEST_HOST=; DEST_DIR=
        return 0
      fi
      save_cfg; echo "  Destination set: $(dest_desc)"
      ;;
    3) edit_sources ;;
    4) ED="${EDITOR:-}"
       # A minimal server image often has neither nano nor an EDITOR set, and
       # "command not found" here looks like the wizard is broken.
       if [ -z "$ED" ]; then
         if command -v nano >/dev/null 2>&1; then ED=nano
         elif command -v vi >/dev/null 2>&1; then ED=vi
         else echo "  No editor found — edit $EXLIST by hand."; return 0; fi
       fi
       "$ED" "$EXLIST" || true
       mapfile -t EXCLUDES < <(grep -vE '^\s*(#|$)' "$EXLIST" 2>/dev/null || true)
       echo "  ${#EXCLUDES[@]} exclude pattern(s) loaded." ;;
    5)
      read -rp "  Keep how many backups [$RETENTION]: " R
      case "$R" in ''|*[!0-9]*) echo "  Unchanged."; return 0 ;; esac
      [ "$R" -lt 1 ] && { echo "  Keep at least 1."; return 0; }
      RETENTION="$R"; save_cfg; echo "  Retention: keep newest $RETENTION."
      ;;
    *) return 0 ;;
  esac
}

# -------------------------------------------------------- non-interactive ----
RUNMODE=interactive
if [ "$1" = "--run" ]; then
  RUNMODE=auto
  if ! try_lock; then
    logline "SKIP: another run holds the lock"
    echo "Another backup-wizard run is in progress — skipping this one." >&2
    exit 1
  fi
  logline "=== scheduled run start ==="
  if ! dest_configured; then
    logline "ABORT: no destination configured"
    echo "No destination configured." >&2
    exit 1
  fi
  # In auto mode everything still prints; the timer/cron line sends it to the log.
  # `do_backup || rc=1` rather than a bare call: under set -e a failed backup
  # would exit here and the run would never write its closing log line, which is
  # exactly the line someone greps for when asking "did last night run at all?".
  RC=0
  do_backup || RC=1
  logline "=== scheduled run end (rc=$RC) ==="
  exit "$RC"
fi

# ------------------------------------------------------------------- menu ----
while :; do
  show
  echo "  1) Show existing backups"
  echo "  2) Back up now"
  echo "  3) Schedule automatic backups"
  echo "  4) Restore from a backup"
  echo "  5) Verify an archive"
  echo "  6) Settings (destination, sources, excludes, retention)"
  echo "  Enter) quit"
  read -rp "  Choice: " CH || CH=""      # EOF (piped stdin) means quit, not crash
  case "$CH" in
    1) list_backups ;;
    2) do_backup || true; unlock ;;
    3) schedule_menu ;;
    4) restore_backup; unlock ;;
    5) verify_backup ;;
    6) settings_menu
       # Settings can change what show() must display, so re-read the lists.
       mapfile -t SOURCES  < <(grep -vE '^\s*(#|$)' "$SRCLIST" 2>/dev/null || true)
       mapfile -t EXCLUDES < <(grep -vE '^\s*(#|$)' "$EXLIST"  2>/dev/null || true)
       ;;
    "") echo "Bye."; exit 0 ;;
    *) echo "  Unknown choice." ;;
  esac
  pause
done
SCRIPT
chmod +x /usr/local/sbin/backup-wizard
echo "Installed. Run:  sudo backup-wizard"
EOF

sudo backup-wizard
