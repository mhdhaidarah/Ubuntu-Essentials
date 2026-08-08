#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/disk-rescue <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

BKDIR=/var/backups/disk-rescue
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BKDIR"

# --------------------------------------------------------------- helpers ---

# df -P forces the POSIX one-line-per-filesystem layout. Without it a long
# device name wraps onto a line of its own and every awk field index shifts by
# one, which is exactly how a "free space" report ends up printing a mount
# option instead of a number. This is always called with one explicit path, so
# df queries that single mount and never walks the whole table - a dead mount
# somewhere else on the machine cannot make it hang.
avail_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# Sizes are carried around in kilobytes and only made human at print time, so
# arithmetic never has to parse "1.4G" back into a number.
hkb() {
  awk -v k="${1:-0}" 'BEGIN {
    s = ""; if (k < 0) { s = "-"; k = -k }
    split("K M G T P", u, " "); i = 1
    while (k >= 1024 && i < 5) { k /= 1024; i++ }
    printf "%s%.1f%s", s, k, u[i]
  }'
}

A_PATH=/
A_BEFORE=0

begin_action() {
  A_PATH="${1:-/}"
  # avail_kb ends in awk, which succeeds even when df failed and printed
  # nothing, so the fallback has to come from the variable and not from
  # a `|| echo` on the substitution (that would print BOTH values).
  A_BEFORE=$(avail_kb "$A_PATH")
  A_BEFORE=${A_BEFORE:-0}
  printf "\n  free on %-12s before : %s\n" "$A_PATH" "$(hkb "$A_BEFORE")"
}

end_action() {
  local after
  after=$(avail_kb "$A_PATH")
  after=${after:-0}
  printf "  free on %-12s after  : %s   (reclaimed %s)\n" \
    "$A_PATH" "$(hkb "$after")" "$(hkb "$((after - A_BEFORE))")"
}

pause() { local x=""; read -r -p "  [enter] to continue " x || true; }

confirm() {
  local a=""
  read -r -p "$1 [y/N]: " a || true
  case "$a" in
    y|Y|yes|YES) return 0 ;;
    *) echo "  Skipped."; return 1 ;;
  esac
}

# For anything irreversible: a whole word, typed exactly, so a stray keypress
# cannot destroy data.
confirm_word() {
  local want="$1" a=""
  read -r -p "  Type $want to proceed (anything else aborts): " a || true
  if [ "$a" = "$want" ]; then return 0; fi
  echo "  Not confirmed. Nothing done."
  return 1
}

# ------------------------------------------------------------ status view ---

show() {
  local warn iwarn tbl
  echo
  echo "Disk usage now:"
  echo "----------------------------------------------------------------------"
  # -l keeps df to LOCAL filesystems. A dropped sshfs or a vanished NFS server
  # makes df either hang or exit non-zero after printing the healthy rows, and
  # remote space is not what this tool reclaims anyway - so skip them at source.
  # Captured, not run inline, because a df that both prints and fails is the
  # classic trap: `df ... || df ...` would print the table twice, and under
  # set -e a failing fallback ends the script. Capture, then test the variable.
  tbl=$(df -hTPl -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null) || true
  if [ -n "$tbl" ]; then
    printf '%s\n' "$tbl"
  else
    echo "  (df could not read the mount table - is a network mount hung?)"
  fi
  echo

  # Column 6 of `df -PT` is Use% and column 7 is the mountpoint. Adding 0 in
  # awk turns "93%" into 93 so it can be compared numerically.
  warn=$(df -PTl -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null \
         | awk 'NR>1 && $6+0 >= 90 {printf "%s(%s) ", $7, $6}') || true
  # A filesystem can be out of INODES with gigabytes free; the kernel still
  # says "No space left on device" and nobody thinks to look, so surface it.
  iwarn=$(df -PiTl -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs 2>/dev/null \
          | awk 'NR>1 && $6+0 >= 80 {printf "%s(%s inodes) ", $7, $6}') || true

  if [ -n "$warn" ];  then printf "  ** NEARLY FULL : %s\n" "$warn"; fi
  if [ -n "$iwarn" ]; then printf "  ** INODES LOW  : %s\n" "$iwarn"; fi
  if [ -z "$warn" ] && [ -z "$iwarn" ]; then echo "  No filesystem is above 90% used."; fi

  # /boot is small and fixed-size, and a full one breaks apt itself, so it gets
  # its own line even when it is nowhere near the warning threshold.
  if [ -d /boot ]; then
    printf "  /boot          : %s\n" "$(df -hP /boot 2>/dev/null | awk 'NR==2 {print $4" free of "$2"  ("$5" used)"}')"
  fi
  echo
}

# ------------------------------------------- 1. where has the space gone ----

biggest_files() {
  local d="$1" out
  echo
  echo "  20 biggest files under $d, over 10M, same filesystem only."
  echo "  On a big tree this walk takes a while - it is reading every inode."
  echo "  ------------------------------------------------------------------"
  # -xdev keeps find on one filesystem, so it never wanders into /proc, into a
  # network mount or onto a second disk, and never counts the same bytes twice.
  # %k is the blocks actually allocated, which is what df is counting - %s would
  # over-report a sparse file and under-report a tiny one.
  out=$(find "$d" -xdev -type f -size +10M -printf '%k %p\n' 2>/dev/null \
    | sort -rn | head -20 \
    | awk '{ k = $1 + 0
             # substr past the first space keeps a filename containing runs of
             # spaces intact - rebuilding $0 in awk would collapse them.
             f = substr($0, index($0, " ") + 1)
             split("K M G T", u, " "); i = 1
             while (k >= 1024 && i < 4) { k /= 1024; i++ }
             printf "  %8.1f%s  %s\n", k, u[i], f }') || true
  # find prints nothing and still succeeds when there is no match, so the empty
  # case has to be detected from the captured text, not from an exit status.
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
  else
    echo "  (no single file over 10M under here)"
  fi
}

where_gone() {
  local d="/" i sz path row choice
  local -a rows paths sizes
  while :; do
    echo
    echo "  Scanning $d one level deep. On a big filesystem this takes a while."
    rows=()
    # du -x stays on one filesystem; the explicit excludes are belt-and-braces
    # for the odd box where /proc or /run somehow shares the root device.
    mapfile -t rows < <(du -kx --max-depth=1 \
        --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run \
        "$d" 2>/dev/null | sort -rn | head -25 || true)

    paths=(); sizes=()
    for row in "${rows[@]}"; do
      sz=${row%%$'\t'*}
      path=${row#*$'\t'}
      # du always reports the directory it was asked about as well; that line
      # is the total, not a child, and picking it would loop forever.
      [ "${path%/}" = "${d%/}" ] && continue
      [ -z "$path" ] && continue
      sizes+=("$sz"); paths+=("$path")
    done

    echo
    printf "  Biggest directories under %s\n" "$d"
    echo "  ------------------------------------------------------------------"
    if [ "${#paths[@]}" -eq 0 ]; then
      echo "  (no sub-directories worth listing here)"
    else
      i=1
      while [ "$i" -le "${#paths[@]}" ]; do
        printf "  %2d) %9s  %s\n" "$i" "$(hkb "${sizes[$((i-1))]}")" "${paths[$((i-1))]}"
        i=$((i+1))
      done
    fi
    echo
    echo "  number = look inside it     u = up one level"
    echo "  f      = biggest FILES here enter = back to menu"
    choice=""
    read -r -p "  > " choice || true
    case "$choice" in
      "") return 0 ;;
      u|U) d=$(dirname "$d") ;;
      f|F) biggest_files "$d"; pause ;;
      *[!0-9]*) echo "  Not a number." ;;
      *)
        if [ "$choice" -ge 1 ] 2>/dev/null && [ "$choice" -le "${#paths[@]}" ]; then
          d="${paths[$((choice-1))]}"
        else
          echo "  Out of range."
        fi
        ;;
    esac
  done
}

# --------------------------------------------------------- 2. the journal ---

reclaim_journal() {
  local usage target
  if ! command -v journalctl >/dev/null 2>&1; then
    echo "  journalctl is not present - this box does not use systemd-journald."
    return 0
  fi
  usage=$(journalctl --disk-usage 2>/dev/null) || true
  echo
  echo "  ${usage:-could not read journal size}"
  if [ -d /var/log/journal ]; then
    echo "  Journal is PERSISTENT (/var/log/journal) - vacuuming frees real disk."
  else
    # A volatile journal lives in /run, which is a tmpfs: it costs RAM, not
    # disk, so vacuuming it will not move the number the operator is watching.
    echo "  Journal is VOLATILE (/run/log/journal, a tmpfs) - it costs RAM, not disk."
  fi
  echo
  echo "  Vacuum the journal down to what size? e.g. 200M, 1G   (enter = skip)"
  target=""
  read -r -p "  size> " target || true
  if [ -z "$target" ]; then echo "  Skipped."; return 0; fi
  if ! printf '%s' "$target" | grep -qE '^[0-9]+[KMG]$'; then
    echo "  '$target' is not a size like 200M or 1G. Nothing done."
    return 0
  fi

  begin_action /var/log
  journalctl --vacuum-size="$target" 2>&1 | tail -3 || true
  end_action

  echo
  echo "  Vacuuming is a one-off. The journal will grow straight back unless"
  echo "  it is capped."
  if confirm "  Cap the journal permanently at $target (SystemMaxUse)?"; then
    mkdir -p /etc/systemd/journald.conf.d
    # A drop-in, never an edit of /etc/systemd/journald.conf: the vendor file
    # stays pristine and undoing this is one file removal instead of trying to
    # un-edit somebody's sed.
    local conf=/etc/systemd/journald.conf.d/99-disk-rescue.conf
    if [ -f "$conf" ]; then cp -a "$conf" "$BKDIR/journald-99-$STAMP.conf"; fi
    cat > "$conf" <<CONF
# Written by disk-rescue on $(date). Delete this file to undo.
[Journal]
SystemMaxUse=$target
CONF
    echo "  Wrote $conf"
    # Restarting journald is supported and does not lose the socket, but if it
    # somehow fails the box is left without logging - so undo immediately.
    if systemctl restart systemd-journald 2>/dev/null; then
      echo "  systemd-journald restarted; cap is live."
    else
      rm -f "$conf"
      systemctl restart systemd-journald 2>/dev/null || true
      echo "  ** journald refused to restart - cap removed, nothing changed."
    fi
  fi
}

# ------------------------------------------------------------- 3. apt ------

reclaim_apt() {
  local cache n sim running
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "  No apt-get here - not a Debian/Ubuntu system."
    return 0
  fi
  cache=$(du -sh /var/cache/apt/archives 2>/dev/null | awk '{print $1}') || true
  n=$(find /var/cache/apt/archives -maxdepth 1 -name '*.deb' 2>/dev/null | wc -l) || true
  echo
  printf "  package cache : %s in %s .deb files\n" "${cache:-0}" "${n:-0}"
  printf "  lists cache   : %s\n" "$(du -sh /var/lib/apt/lists 2>/dev/null | awk '{print $1}')"

  if confirm "  Empty the .deb cache (apt-get clean)? Packages re-download on demand."; then
    begin_action /var
    apt-get clean || true
    apt-get autoclean -y >/dev/null 2>&1 || true
    end_action
  fi

  echo
  echo "  Checking what autoremove would take away (simulation only)..."
  sim=$(apt-get -s autoremove --purge 2>/dev/null) || true
  local -a rem=()
  mapfile -t rem < <(printf '%s\n' "$sim" | awk '/^Remv /{print $2}') || true
  if [ "${#rem[@]}" -eq 0 ]; then
    echo "  Nothing to autoremove."
    return 0
  fi
  printf '%s\n' "${rem[@]}" | sed 's/^/    /'
  printf "  %d package(s) would be purged.\n" "${#rem[@]}"

  # apt normally protects the running kernel, but if a broken dependency state
  # has confused it the simulation will happily list it - and removing the
  # kernel you are booted from leaves an unbootable machine. Refuse outright.
  running=$(uname -r)
  if printf '%s\n' "${rem[@]}" | grep -q -- "$running"; then
    echo
    echo "  ** REFUSING: the simulation includes the RUNNING kernel ($running)."
    echo "     Fix the package state first:  apt-get -f install"
    return 0
  fi
  echo "  Note: anything you installed by hand but apt has marked automatic is"
  echo "  in that list too. Read it before agreeing."
  if confirm "  Run apt-get autoremove --purge for real?"; then
    begin_action /
    apt-get -y autoremove --purge || echo "  ** apt failed - if /boot is full, use menu 4 first."
    end_action
  fi
}

# --------------------------------------------------------- 4. old kernels ---

# Size of everything on disk belonging to one kernel version, in KB.
ksize_kb() {
  local v="$1" t=0 s=""
  s=$(du -sk "/lib/modules/$v" 2>/dev/null | awk '{print $1}') || true
  t=$((t + ${s:-0}))
  # The glob is unquoted on purpose so it expands; when nothing matches, du is
  # handed the literal pattern, fails quietly, and awk prints nothing - hence
  # the :-0 default rather than trusting the exit status.
  s=$(du -sck /boot/*-"$v" 2>/dev/null | awk '/total$/{print $1}') || true
  t=$((t + ${s:-0}))
  echo "$t"
}

old_kernels() {
  local running spare v abi i choice pct
  local -a imgs=() keep=() drop=() pkgs=() p=() narrow=()

  if ! command -v dpkg-query >/dev/null 2>&1; then
    echo "  No dpkg here - kernel cleanup is Debian/Ubuntu only."
    return 0
  fi
  running=$(uname -r)

  # Only versioned images are candidates. The meta-packages (linux-image-generic,
  # linux-image-virtual) carry no version in the name, and purging one of those
  # stops the machine ever receiving another kernel update - so the pattern
  # deliberately requires a digit.
  mapfile -t imgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' \
      'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' 2>/dev/null \
      | awk '$1 ~ /^ii/ {print $2}' \
      | sed -e 's/^linux-image-unsigned-//' -e 's/^linux-image-//' \
      | sort -u -V) || true

  if [ "${#imgs[@]}" -eq 0 ]; then
    echo "  No versioned kernel packages installed (container or custom kernel?)."
    return 0
  fi

  # Keep the running kernel, always. Keep one spare besides it - the highest
  # version that is not running - because a kernel that panics on boot leaves
  # the GRUB menu as the only way back in, and an empty menu is a rescue-disk
  # trip. imgs is ascending, so the last non-running entry is the newest.
  spare=""
  for v in "${imgs[@]}"; do
    if [ "$v" != "$running" ]; then spare="$v"; fi
  done
  keep=("$running")
  if [ -n "$spare" ]; then keep+=("$spare"); fi

  drop=()
  for v in "${imgs[@]}"; do
    if [ "$v" = "$running" ] || [ "$v" = "$spare" ]; then continue; fi
    drop+=("$v")
  done

  echo
  printf "  /boot: %s\n" "$(df -hP /boot 2>/dev/null | awk 'NR==2 {print $4" free of "$2", "$5" used"}')"
  echo
  echo "  Installed kernels"
  echo "  ------------------------------------------------------------------"
  for v in "${imgs[@]}"; do
    if [ "$v" = "$running" ]; then
      printf "  %-32s %9s  RUNNING - never removed\n" "$v" "$(hkb "$(ksize_kb "$v")")"
    elif [ "$v" = "$spare" ]; then
      printf "  %-32s %9s  keep as fallback\n" "$v" "$(hkb "$(ksize_kb "$v")")"
    else
      printf "  %-32s %9s  removable\n" "$v" "$(hkb "$(ksize_kb "$v")")"
    fi
  done
  echo

  # Booted on something older than the newest installed kernel usually means a
  # kernel upgrade is waiting for a reboot. Saying so avoids the operator
  # deleting the new one by hand later, wondering why it never took effect.
  if [ "$running" != "${imgs[-1]}" ]; then
    echo "  Note: you are running $running but ${imgs[-1]} is installed."
    echo "        Reboot to use it; until then it is treated as the spare."
    echo
  fi

  if [ "${#drop[@]}" -eq 0 ]; then
    echo "  Nothing to remove: only the running kernel and one spare are installed."
    return 0
  fi

  pct=$(df -PT /boot 2>/dev/null | awk 'NR==2 {print $6+0}') || true
  pct=${pct:-0}
  if [ "$pct" -ge 95 ]; then
    echo "  ** /boot is ${pct}% full. This is the deadlock case: the kernel"
    echo "     packages run update-initramfs in their own postrm, that needs"
    echo "     free space in /boot, so apt cannot complete the very purge that"
    echo "     would create the space. If the purge below fails, come back and"
    echo "     choose the emergency option."
    echo
  fi

  echo "  Will purge ${#drop[@]} kernel version(s):"
  printf '    %s\n' "${drop[@]}"
  echo
  echo "  1) Purge them with apt (normal path)"
  echo "  2) EMERGENCY: delete one old initrd by hand first, then purge"
  echo "     (only when /boot is so full that apt cannot run)"
  echo "  enter) back"
  choice=""
  read -r -p "  > " choice || true
  if [ -z "$choice" ]; then return 0; fi

  # The honest backup here is the package LIST, not the files: copying kernels
  # aside would consume the very space being reclaimed. The list is enough to
  # reinstall any of them byte-identical from the archive.
  dpkg -l > "$BKDIR/packages-$STAMP.txt" 2>/dev/null || true
  echo "  Package list saved to $BKDIR/packages-$STAMP.txt"

  if [ "$choice" = "2" ]; then
    v="${drop[0]}"
    echo
    echo "  Emergency: removing /boot files of $v by hand to make room."
    echo "  This leaves dpkg thinking the package is still installed; the purge"
    echo "  immediately afterwards is what puts the database straight again."
    ls -la /boot/*-"$v" 2>/dev/null || true
    if confirm_word WIPE; then
      begin_action /boot
      rm -f /boot/initrd.img-"$v" || true
      end_action
    else
      return 0
    fi
  fi

  # Assemble the exact package set for the versions being dropped.
  pkgs=()
  for v in "${drop[@]}"; do
    abi="${v%-*}"
    p=()
    mapfile -t p < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
        | awk '$1 ~ /^ii/ {print $2}' \
        | grep -E "^linux-(image|image-unsigned|headers|modules|modules-extra|tools|cloud-tools|buildinfo)-(${v}|${abi})$" || true)
    # linux-headers-<abi> and linux-tools-<abi> are shared by every flavour of
    # that ABI (-generic and -lowlatency for instance). If a kernel we are
    # keeping has the same ABI, removing the shared package would break it, so
    # narrow down to the flavour-specific names.
    if printf '%s\n' "${keep[@]}" | grep -q -- "^${abi}-"; then
      narrow=()
      mapfile -t narrow < <(printf '%s\n' "${p[@]}" | grep -E -- "-${v}$" || true)
      p=("${narrow[@]}")
    fi
    pkgs+=("${p[@]}")
  done

  # Last line of defence before handing the list to apt: whatever the logic
  # above did, nothing belonging to the running kernel may be in it.
  if printf '%s\n' "${pkgs[@]}" | grep -q -- "$running"; then
    echo "  ** REFUSING: the computed package list touches the running kernel."
    return 0
  fi
  if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "  Nothing to purge after filtering."
    return 0
  fi

  echo
  echo "  Packages to purge:"
  printf '    %s\n' "${pkgs[@]}"
  echo
  if ! confirm_word YES; then return 0; fi

  begin_action /boot
  if apt-get -y purge "${pkgs[@]}"; then
    echo "  Purge completed."
  else
    echo "  ** apt failed. Try:  apt-get -f install   then run this again."
    echo "     If it complains that /boot is full, use the emergency option."
  fi
  # Kernel packages normally refresh GRUB from their own hooks, but if a hook
  # was skipped the menu would still offer a kernel that is no longer there.
  command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 || true
  end_action
  echo "  Kernels still installed:"
  dpkg-query -W -f='    ${Package}\n' 'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' 2>/dev/null || true
}

# ----------------------------------------------------------- 5. docker -----

docker_reclaim() {
  local root choice
  if ! command -v docker >/dev/null 2>&1; then
    echo "  Docker is not installed."
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    echo "  Docker is installed but the daemon is not answering - start it first."
    return 0
  fi
  # Prune frees space wherever the data root lives, which is often a separate
  # disk from /, so before/after must be measured there and not on /.
  root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null) || true
  root=${root:-/var/lib/docker}
  echo
  echo "  data root: $root"
  echo
  docker system df 2>/dev/null || true
  echo
  printf "  containers: %s running, %s total\n" \
    "$(docker ps -q 2>/dev/null | wc -l)" "$(docker ps -aq 2>/dev/null | wc -l)"
  echo
  echo "  1) Safe prune    - stopped containers, dangling images, build cache"
  echo "  2) Hard prune    - the above PLUS every image no container uses"
  echo "  3) Build cache only"
  echo "  4) Volumes       - DESTROYS DATA (databases live here)"
  echo "  enter) back"
  choice=""
  read -r -p "  > " choice || true
  case "$choice" in
    1)
      echo "  Stopped containers go too - a compose stack that is merely 'down'"
      echo "  loses its containers, though 'up' recreates them."
      if confirm "  Proceed?"; then
        begin_action "$root"
        docker system prune -f || true
        end_action
      fi
      ;;
    2)
      echo "  Every image not attached to a container is deleted, so anything"
      echo "  you still need will have to be pulled again over the network."
      if confirm "  Proceed?"; then
        begin_action "$root"
        docker system prune -af || true
        end_action
      fi
      ;;
    3)
      begin_action "$root"
      docker builder prune -af || true
      end_action
      ;;
    4)
      echo
      echo "  ** A named volume is where a container keeps its PERSISTENT data:"
      echo "     database files, uploads, certificates. Pruning removes every"
      echo "     volume no running container references - including the volumes"
      echo "     of a stack that is simply stopped. There is no undo."
      docker volume ls 2>/dev/null || true
      echo
      if confirm_word DESTROY; then
        begin_action "$root"
        docker volume prune -f || true
        end_action
      fi
      ;;
    *) return 0 ;;
  esac
}

# ------------------------------------------- 6. deleted but still open ------

deleted_open() {
  local fd link pid sz key comm unit total=0 n=0 target
  local -A seen=()
  local -a pids=()

  echo
  echo "  Files unlinked from the tree while a process still holds them open."
  echo "  df counts those blocks, du cannot see them, and only closing the file"
  echo "  descriptor gives them back - which in practice means restarting the"
  echo "  process that is holding it."
  echo
  printf "  %-8s %-18s %10s  %s\n" "PID" "PROCESS" "SIZE" "DELETED PATH"
  echo "  ------------------------------------------------------------------"

  for fd in /proc/[0-9]*/fd/*; do
    # readlink fails for a process that exited between the glob and here, and
    # for descriptors this shell is not allowed to inspect. Both are normal.
    link=$(readlink "$fd" 2>/dev/null) || continue
    case "$link" in
      *" (deleted)") ;;
      *) continue ;;
    esac
    # A memfd is anonymous memory that always reports itself as deleted; it
    # occupies RAM, never disk, so counting it would send the operator chasing
    # space that df never lost.
    case "$link" in
      /memfd:*|"/dev/zero"*|/anon_hugepage*|"/[aio]"*) continue ;;
    esac
    sz=$(stat -Lc %s "$fd" 2>/dev/null) || continue
    [ "${sz:-0}" -ge 10485760 ] || continue
    # The same deleted file is usually open on several descriptors and often in
    # several processes; keying on device+inode stops the total double-counting.
    key=$(stat -Lc '%d:%i' "$fd" 2>/dev/null) || continue
    if [ -n "${seen[$key]:-}" ]; then continue; fi
    seen[$key]=1
    pid=${fd#/proc/}; pid=${pid%%/*}
    comm=$(cat "/proc/$pid/comm" 2>/dev/null) || comm="?"
    printf "  %-8s %-18s %10s  %s\n" "$pid" "$comm" "$(hkb "$((sz / 1024))")" "${link% (deleted)}"
    total=$((total + sz / 1024))
    n=$((n + 1))
    pids+=("$pid")
  done

  if [ "$n" -eq 0 ]; then
    echo "  (nothing over 10M - no hidden space of this kind)"
    return 0
  fi
  echo "  ------------------------------------------------------------------"
  printf "  %d file(s), %s held open.\n" "$n" "$(hkb "$total")"
  echo
  echo "  Restart the holder to release it. Enter a PID from the list,"
  echo "  or press enter to leave everything alone."
  target=""
  read -r -p "  pid> " target || true
  if [ -z "$target" ]; then return 0; fi
  if ! printf '%s' "$target" | grep -qE '^[0-9]+$'; then echo "  Not a pid."; return 0; fi
  # Only a pid from the table above is worth restarting. Restarting anything
  # else is a self-inflicted outage that frees nothing, so refuse it rather
  # than trust a mistyped number.
  if ! printf '%s\n' "${pids[@]}" | grep -qx -- "$target"; then
    echo "  $target is not one of the pids listed above - restarting it would"
    echo "  cause an outage and free nothing. Nothing done."
    return 0
  fi
  if [ ! -d "/proc/$target" ]; then echo "  No such process any more."; return 0; fi

  comm=$(cat "/proc/$target/comm" 2>/dev/null) || comm="?"
  if [ "$target" = "1" ]; then
    echo "  ** That is pid 1. Refusing: it cannot be restarted without rebooting."
    return 0
  fi
  # Reading the cgroup line is how a pid is mapped back to its systemd unit;
  # `systemctl status <pid>` would do it too but has to be parsed out of prose.
  unit=$(awk -F/ '{for (i=1; i<=NF; i++) if ($i ~ /\.service$/) { print $i; exit }}' \
         "/proc/$target/cgroup" 2>/dev/null) || true

  if [ -z "$unit" ]; then
    echo "  Process $target ($comm) is not run by a systemd service, so there is"
    echo "  no safe automatic way to cycle it. Restart it the way it was started."
    echo "  Killing it blind could take down something this session depends on."
    return 0
  fi

  echo "  pid $target ($comm) belongs to unit: $unit"
  case "$unit" in
    ssh.service|sshd.service)
      echo "  ** That is the SSH server. Restarting it does not drop the session"
      echo "     you are in, but if the config is broken you will not get back."
      echo "     Verify first:  sshd -t"
      if ! confirm_word YES; then return 0; fi
      ;;
  esac

  begin_action /
  if systemctl restart "$unit"; then
    echo "  $unit restarted."
  else
    echo "  ** restart failed - check: systemctl status $unit"
  fi
  end_action
}

# ------------------------------------------------------------- main -------

while :; do
  show
  cat <<'MENU'
  What would you like to do?
  ----------------------------------------------------------------------
  1) Where has it gone   - biggest directories, then biggest files
  2) Reclaim journal     - vacuum systemd logs, optionally cap them
  3) Reclaim apt         - package cache and autoremove
  4) Old kernels         - purge all but the running one and one spare
  5) Docker              - prune images, containers, cache, volumes
  6) Deleted-but-open    - space df sees and du cannot find
  enter) quit
MENU
  CHOICE=""
  read -r -p "  Choice: " CHOICE || true
  case "$CHOICE" in
    1) where_gone ;;
    2) reclaim_journal; pause ;;
    3) reclaim_apt; pause ;;
    4) old_kernels; pause ;;
    5) docker_reclaim; pause ;;
    6) deleted_open; pause ;;
    "") echo "  Bye."; exit 0 ;;
    *) echo "  Not an option." ;;
  esac
done
SCRIPT
chmod +x /usr/local/sbin/disk-rescue
echo "Installed. Run:  sudo disk-rescue"
EOF

sudo disk-rescue