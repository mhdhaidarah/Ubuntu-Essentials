#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/swap-setup <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

REG=/etc/swap-setup.files                     # one path per line: swap files this tool created
# Debian/Ubuntu ship /etc/sysctl.d/99-sysctl.conf as a SYMLINK to /etc/sysctl.conf, and
# systemd-sysctl applies the drop-ins in filename order. A "60-" file therefore loses to
# anything the operator wrote in /etc/sysctl.conf. "99-zz-" sorts after "99-sysctl.conf",
# so our value is the one that survives a reboot.
SYSCTLF=/etc/sysctl.d/99-zz-swap-setup.conf
FSTAB=/etc/fstab
STAMP=$(date +%Y%m%d-%H%M%S)

line() { printf -- '--------------------------------------------------------------\n'; }

# Everything zram-related is a systemd unit. Decide once whether systemd is actually
# running (a chroot or a container can have the binary but no init) instead of guessing
# at five call sites.
HAVE_SYSTEMD=""
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then HAVE_SYSTEMD=1; fi

# systemd-detect-virt PRINTS "none" and EXITS 1 when this is not a container, so it is
# exactly the "prints and fails" trap: capture with || true, then test the VALUE. The
# binary itself is missing on non-systemd systems, hence the command -v guard.
IN_CONTAINER=""
if command -v systemd-detect-virt >/dev/null 2>&1; then
  VIRT=$(systemd-detect-virt --container 2>/dev/null) || true
  if [ -n "$VIRT" ] && [ "$VIRT" != "none" ]; then IN_CONTAINER="$VIRT"; fi
elif [ -f /run/systemd/container ]; then
  IN_CONTAINER=$(cat /run/systemd/container 2>/dev/null) || true
elif [ -f /.dockerenv ]; then
  IN_CONTAINER="docker"
fi

ram_mb() { awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo; }

mem_avail_mb() {
  local v
  v=$(awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo) || true
  # MemAvailable is absent on kernels older than 3.14. MemFree under-reports (it ignores
  # reclaimable page cache), which only ever makes the swapoff safety check stricter.
  if [ -z "$v" ]; then v=$(awk '/^MemFree:/ {printf "%d", $2/1024}' /proc/meminfo) || true; fi
  printf '%d' "${v:-0}"
}

human_mb() {
  local mb="${1:-0}"
  # Callers pass values that came out of awk/df; a stray empty string would make the
  # numeric test below abort the whole script under set -e.
  printf '%s' "$mb" | grep -qE '^-?[0-9]+$' || mb=0
  if [ "$mb" -ge 1024 ]; then awk -v m="$mb" 'BEGIN{printf "%.1fG", m/1024}'; else printf '%dM' "$mb"; fi
}

# Suggested swap file size: tiny boxes need a real cushion, big boxes do not.
suggest_mb() {
  local ram sug
  ram=$(ram_mb)
  ram="${ram:-1024}"
  if [ "$ram" -le 2048 ]; then sug=$((ram * 2)); else sug="$ram"; fi
  if [ "$sug" -gt 8192 ]; then sug=8192; fi
  if [ "$sug" -lt 512 ]; then sug=512; fi
  printf '%d' "$sug"
}

# Accepts 2G / 2048M / 1.5G / bare number (treated as GB). Prints MB on success and
# prints NOTHING on failure -- a function that prints nothing still EXITS 0, so the
# caller must test the captured variable, never the exit status.
parse_size_mb() {
  local s num mult
  s=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
  case "$s" in
    *GB) num="${s%GB}"; mult=1024 ;;
    *MB) num="${s%MB}"; mult=1 ;;
    *G)  num="${s%G}";  mult=1024 ;;
    *M)  num="${s%M}";  mult=1 ;;
    *)   num="$s";      mult=1024 ;;
  esac
  printf '%s' "$num" | grep -qE '^[0-9]+([.][0-9]+)?$' || return 0
  awk -v n="$num" -v m="$mult" 'BEGIN{printf "%d", n*m}'
}

swap_used_mb() {
  local u
  u=$(swapon --show=NAME,USED --bytes --noheadings 2>/dev/null | awk -v p="$1" '$1==p {printf "%d", $2/1048576}') || true
  printf '%d' "${u:-0}"
}

# Turning a swap area off copies every page still living in it back into RAM. If that
# does not fit, swapoff itself invokes the OOM killer -- precisely the 3am incident this
# tool exists to prevent -- so do the arithmetic BEFORE touching anything. Prints the
# explanation and returns 0 ("yes, it would OOM") so callers can just say `if ...`.
swapoff_would_oom() {
  local used avail
  used=$(swap_used_mb "$1")
  avail=$(mem_avail_mb)
  # 256M of slack: the kernel needs headroom for the copy itself, not just the pages.
  if [ "$used" -gt 0 ] && [ "$used" -gt $((avail - 256)) ]; then
    printf "  Refusing: %s holds %s of live pages but only %s of RAM is available.\n" \
      "$1" "$(human_mb "$used")" "$(human_mb "$avail")"
    echo "  swapoff would pull those pages into RAM and OOM-kill something."
    echo "  Stop a service or add another swap area first, then retry."
    echo "  (If you accept the risk, run it by hand: swapoff $1)"
    return 0
  fi
  return 1
}

swappiness_note() {
  cat <<'NOTE'
  What swappiness really is: NOT "how much swap to use". It is the kernel's relative
  preference, under memory pressure, for reclaiming anonymous pages (a process's own
  heap/stack -> must be written to swap) versus dropping file-backed page cache
  (already on disk -> free to discard). High values swap idle program memory out early
  and protect the cache; low values throw away cache first and only swap when it must.
  0 does NOT disable swap -- it just makes the kernel avoid it until it is nearly OOM.
  Rules of thumb: 10 for a DB/latency-sensitive box, 60 kernel default, 100 with zram
  (swapping to compressed RAM is cheap, so let it happen freely).
NOTE
}

show_state() {
  local ram sw sp vc z algo disk
  ram=$(ram_mb)
  line
  printf "  %-22s %s MB\n" "RAM total:" "${ram:-?}"
  sp=$(cat /proc/sys/vm/swappiness 2>/dev/null) || true
  vc=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null) || true
  printf "  %-22s %s\n" "vm.swappiness:" "${sp:-?}"
  printf "  %-22s %s\n" "vm.vfs_cache_pressure:" "${vc:-?}"
  if [ -f "$SYSCTLF" ]; then printf "  %-22s %s\n" "persisted in:" "$SYSCTLF"; fi
  if [ -n "$IN_CONTAINER" ]; then printf "  %-22s %s\n" "container:" "$IN_CONTAINER"; fi
  if [ -z "$HAVE_SYSTEMD" ]; then printf "  %-22s %s\n" "systemd:" "not running (zram options disabled)"; fi
  echo
  echo "  Active swap:"
  # swapon --show prints nothing at all when there is no swap, and still exits 0.
  sw=$(swapon --show 2>/dev/null) || true
  if [ -z "$sw" ]; then
    echo "    (none)  <-- an OOM kill here takes out your database, not a cache"
  else
    printf '%s\n' "$sw" | sed 's/^/    /'
  fi
  echo
  # zram detail is only in sysfs; the swap table just shows /dev/zram0.
  for z in /sys/block/zram*; do
    [ -e "$z/disksize" ] || continue
    disk=$(cat "$z/disksize" 2>/dev/null) || true
    if [ "${disk:-0}" = "0" ]; then continue; fi
    algo=$(cat "$z/comp_algorithm" 2>/dev/null) || true
    printf "  zram %-10s size=%s  algo=%s\n" "$(basename "$z")" \
      "$(human_mb "$(( ${disk:-0} / 1048576 ))")" "${algo:-?}"
  done
  echo
  echo "  free -h:"
  free -h | sed 's/^/    /'
  if [ -s "$REG" ]; then
    echo
    echo "  Swap files created by this tool:"
    sed 's/^/    /' "$REG"
  fi
  line
}

backup_fstab() {
  cp -a "$FSTAB" "$FSTAB.bak-$STAMP"
  printf "  Backed up %s -> %s\n" "$FSTAB" "$FSTAB.bak-$STAMP"
}

# An fstab that does not end in a newline would silently glue our first appended
# character onto the operator's last mount line and corrupt it at the next boot.
fstab_ensure_newline() {
  local last
  last=$(tail -c1 "$FSTAB" 2>/dev/null) || true
  if [ -n "$last" ]; then printf '\n' >> "$FSTAB"; fi
}

# Create, format and activate a swap file, cleaning up after itself on every failure so
# a half-built file is never left behind for the next run to trip over.
#   0 = success, 1 = hard failure, 2 = failed in a way a dd rewrite might fix.
build_swap() {
  local f="$1" mb="$2" method="$3" nocow="$4"
  rm -f "$f"                       # only ever our own path: the caller refused pre-existing files
  ( umask 077; : > "$f" ) || return 1
  chown root:root "$f" 2>/dev/null || true
  chmod 600 "$f"
  if [ "$nocow" = "1" ]; then
    # btrfs refuses to swap on a file with copy-on-write or compression, and chattr +C
    # only takes effect while the file is still EMPTY -- hence create, set, then fill.
    chattr +C "$f" 2>/dev/null || true
  fi
  if [ "$method" = "fallocate" ]; then
    if ! fallocate -l "${mb}M" "$f" 2>/dev/null; then
      rm -f "$f"
      return 2
    fi
  else
    printf "  Writing %s with dd, this can take a while...\n" "$(human_mb "$mb")"
    if ! dd if=/dev/zero of="$f" bs=1M count="$mb" status=none 2>/dev/null; then
      rm -f "$f"
      return 1
    fi
  fi
  chmod 600 "$f"
  if ! mkswap "$f" >/dev/null 2>&1; then rm -f "$f"; return 1; fi
  if ! swapon "$f" 2>/dev/null; then rm -f "$f"; return 2; fi
  # Trust the swap table, not the exit status: only a swap the kernel really registered
  # may go into fstab, or every future boot logs an activation failure forever.
  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$f"; then
    swapoff "$f" 2>/dev/null || true
    rm -f "$f"
    return 2
  fi
  return 0
}

# ---------------------------------------------------------------- add swap file
add_swapfile() {
  local f dir fstype avail want ans mb method nocow rc
  if [ -n "$IN_CONTAINER" ]; then
    echo "  Refusing: this is a $IN_CONTAINER container. swapon() is blocked inside"
    echo "  containers (the host kernel owns swap). Add swap on the HOST instead."
    return 0
  fi

  read -rp "  Swap file path [/swapfile]: " f || f=""
  f="${f:-/swapfile}"
  case "$f" in /*) : ;; *) echo "  Need an absolute path."; return 0 ;; esac
  # fstab splits on whitespace and treats # as a comment, so such a path would produce a
  # line that boots wrong. Escaping (\040) exists but is not worth the footgun.
  case "$f" in
    *[[:space:]]*|*"#"*)
      echo "  Refusing: an fstab path may not contain whitespace or '#'."
      echo "  Use a plain path such as /swapfile or /var/swapfile."
      return 0 ;;
  esac
  # /tmp is wiped at boot on many systems and the rest are virtual filesystems: the file
  # would vanish and leave a permanently failing fstab entry.
  case "$f" in
    /proc/*|/sys/*|/dev/*|/run/*|/tmp/*)
      echo "  Refusing: $f is on a volatile or virtual filesystem; the file would not"
      echo "  survive a reboot but the $FSTAB entry would."
      return 0 ;;
  esac
  # -e is FALSE for a dangling symlink, so test -L too: otherwise we would happily write
  # our swap file through someone's broken link into an unexpected place.
  if [ -e "$f" ] || [ -L "$f" ]; then
    echo "  $f already exists. Use option 4 to remove it first, or pick another path."
    return 0
  fi
  dir=$(dirname "$f")
  [ -d "$dir" ] || { echo "  Directory $dir does not exist."; return 0; }

  fstype=$(findmnt -no FSTYPE --target "$dir" 2>/dev/null) || true
  # Written as an explicit if: `A && B || C` groups as `((A||B))&&C` and would run the
  # fallback for the wrong reason.
  if [ -z "$fstype" ]; then
    fstype=$(stat -f -c %T "$dir" 2>/dev/null) || true
  fi
  printf "  Filesystem at %-14s %s\n" "$dir:" "${fstype:-unknown}"
  case "$fstype" in
    zfs)
      echo "  Refusing: a swap file on ZFS can deadlock the kernel under memory"
      echo "  pressure (ZFS needs memory to write out the very pages being swapped)."
      echo "  Use option 3 (zram) or a real swap ZVOL/partition instead."
      return 0 ;;
    tmpfs|ramfs|overlay|overlayfs|nfs|nfs4|cifs|fuse*)
      echo "  Refusing: $fstype cannot host a usable swap file (it is RAM-backed or"
      echo "  over the network). Pick a path on a real local disk."
      return 0 ;;
  esac

  want=$(suggest_mb)
  read -rp "  Size - a bare number means GB (e.g. 2G, 512M) [$(human_mb "$want")]: " ans || ans=""
  if [ -n "$ans" ]; then
    mb=$(parse_size_mb "$ans")
    # parse_size_mb prints nothing on bad input, so test the VALUE, not the status.
    if [ -z "$mb" ] || [ "$mb" -lt 64 ]; then
      echo "  Not a valid size (minimum 64M)."
      return 0
    fi
  else
    mb="$want"
  fi

  # --output=avail (coreutils 8.21+, so every supported Ubuntu) gives one clean number and
  # cannot be knocked out of alignment by a device or mount point containing spaces.
  avail=$(df -m --output=avail "$dir" 2>/dev/null | awk 'NR==2 {print $1}') || true
  if [ -z "$avail" ]; then
    avail=$(df -Pm "$dir" 2>/dev/null | awk 'NR==2 {print $4}') || true
  fi
  if [ -z "$avail" ]; then echo "  Could not read free space on $dir."; return 0; fi
  printf "  Free space on %-14s %s\n" "$dir:" "$(human_mb "$avail")"
  # 256M of headroom: a filesystem at 100% full breaks logging, apt and postgres.
  if [ "$avail" -lt $((mb + 256)) ]; then
    echo "  Refusing: need $(human_mb "$mb") + 256M headroom, only $(human_mb "$avail") free."
    return 0
  fi

  echo
  echo "  Will create $f of $(human_mb "$mb"), mkswap + swapon, and persist in $FSTAB."
  read -rp "  Proceed? [y/N]: " ans || ans=""
  case "$ans" in y|Y|yes|YES) : ;; *) echo "  Cancelled."; return 0 ;; esac

  # fallocate is instant, but it only reserves UNWRITTEN extents; XFS (and btrfs) hand
  # those to swapon, which rejects them with "swapfile has holes". Those filesystems must
  # be written out for real, so start with dd there and keep dd as the universal retry.
  method="fallocate"
  nocow="0"
  case "$fstype" in
    xfs)   method="dd" ;;
    btrfs) method="dd"; nocow="1" ;;
  esac

  rc=0
  build_swap "$f" "$mb" "$method" "$nocow" || rc=$?
  if [ "$rc" != "0" ] && [ "$method" = "fallocate" ]; then
    echo "  The fallocate route did not yield a usable swap file; retrying with dd (slower)..."
    rc=0
    build_swap "$f" "$mb" "dd" "$nocow" || rc=$?
  fi
  if [ "$rc" != "0" ]; then
    echo "  Could not create a working swap file at $f. Nothing changed."
    return 0
  fi

  if awk -v p="$f" '$1==p && $3=="swap" {found=1} END {exit !found}' "$FSTAB"; then
    echo "  $FSTAB already had an entry for $f - left it alone."
  else
    backup_fstab
    fstab_ensure_newline
    printf '# swap-setup: %s (added %s)\n%s none swap sw 0 0\n' "$f" "$STAMP" "$f" >> "$FSTAB"
    echo "  Added the $FSTAB entry so the swap comes back after a reboot."
  fi
  grep -qxF "$f" "$REG" 2>/dev/null || printf '%s\n' "$f" >> "$REG"
  echo "  Done: $(human_mb "$mb") of swap active at $f."
}

# ---------------------------------------------------------------------- zram
# zram-tools has used more than one unit name across releases; find whichever is really
# installed. Prints nothing when there is none, so callers must test the VALUE.
zram_unit() {
  local u
  for u in zramswap.service zram-config.service; do
    if systemctl list-unit-files --no-legend "$u" 2>/dev/null | awk -v n="$u" '$1==n {f=1} END {exit !f}'; then
      printf '%s' "$u"
      return 0
    fi
  done
  return 0
}

setup_zram() {
  local pct ans unit act cfg was_enabled d tries
  echo
  echo "  zram = a compressed block device living in RAM, used as swap. Pages are"
  echo "  compressed (typically 2-3x) instead of written to disk, so it costs a little"
  echo "  CPU and no I/O. On a small VPS with slow storage it is the better cushion;"
  echo "  it does NOT survive reboot and cannot hold hibernation, and it gives you no"
  echo "  extra memory beyond compression - a disk swap file is still the deeper net."
  echo
  if [ -n "$IN_CONTAINER" ]; then
    echo "  Refusing: this is a $IN_CONTAINER container - it has no control over the"
    echo "  host's zram devices. Configure zram on the HOST."
    return 0
  fi
  if [ -z "$HAVE_SYSTEMD" ]; then
    echo "  Refusing: systemd is not running here, and every zram package on Debian/"
    echo "  Ubuntu ships its configuration as a systemd unit."
    return 0
  fi
  if [ -e /etc/systemd/zram-generator.conf ]; then
    echo "  /etc/systemd/zram-generator.conf exists: systemd-zram-generator is already"
    echo "  managing zram on this box. Refusing to add a second manager - edit that"
    echo "  file instead, or remove it first."
    return 0
  fi
  # zram-config is a DIFFERENT package with its own config; writing /etc/default/zramswap
  # under it would look like it worked and change nothing.
  if dpkg -s zram-config >/dev/null 2>&1; then
    echo "  The zram-config package owns zram here. Refusing to fight it: configure it"
    echo "  through its own files, or 'apt-get purge zram-config' first."
    return 0
  fi

  act=$(swapon --show=NAME --noheadings 2>/dev/null | grep '^/dev/zram') || true
  if [ -n "$act" ]; then
    echo "  zram is already active:"
    printf '%s\n' "$act" | sed 's/^/    /'
    echo "    1) reconfigure size"
    echo "    2) disable zram"
    echo "    Enter) back"
    read -rp "  Choice: " ans || ans=""
    case "$ans" in
      1)
        # Reconfiguring restarts the unit, which is a swapoff first: same OOM arithmetic.
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          if swapoff_would_oom "$d"; then return 0; fi
        done <<< "$act"
        ;;
      2)
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          if swapoff_would_oom "$d"; then return 0; fi
        done <<< "$act"
        read -rp "  Type YES to turn zram off: " ans || ans=""
        [ "$ans" = "YES" ] || { echo "  Cancelled."; return 0; }
        unit=$(zram_unit) || true
        if [ -n "$unit" ]; then
          systemctl disable --now "$unit" >/dev/null 2>&1 || true
        fi
        while IFS= read -r d; do
          [ -n "$d" ] || continue
          swapoff "$d" 2>/dev/null || true
        done <<< "$act"
        echo "  zram disabled (config left in /etc/default/zramswap for reference)."
        return 0 ;;
      *) return 0 ;;
    esac
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "  Refusing: no apt-get - this installer only knows Debian/Ubuntu packaging."
    return 0
  fi
  if ! dpkg -s zram-tools >/dev/null 2>&1; then
    echo "  Installing zram-tools..."
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      if ! DEBIAN_FRONTEND=noninteractive apt-get install -y zram-tools >/dev/null 2>&1; then
        echo "  Failed to install zram-tools (no network, or universe not enabled)."
        return 0
      fi
    fi
  fi

  echo "  Size is a percentage of RAM. 50% is a sane default: it compresses down to"
  echo "  roughly 20% of RAM actually consumed. Over ~100% you spend more RAM on"
  echo "  metadata than you win back."
  read -rp "  Percent of RAM for zram [50]: " pct || pct=""
  pct="${pct:-50}"
  if ! printf '%s' "$pct" | grep -qE '^[0-9]+$'; then
    echo "  Enter a whole number between 5 and 200."
    return 0
  fi
  if [ "$pct" -lt 5 ] || [ "$pct" -gt 200 ]; then
    echo "  Enter a whole number between 5 and 200."
    return 0
  fi

  unit=$(zram_unit) || true
  if [ -z "$unit" ]; then
    echo "  zram-tools is installed but ships no service unit we recognise; cannot"
    echo "  enable it safely. Nothing changed."
    return 0
  fi
  # systemctl is-enabled PRINTS "disabled" and EXITS 1 - capture with || true and test the
  # value, so that a rollback can put the enablement back exactly as we found it.
  was_enabled=$(systemctl is-enabled "$unit" 2>/dev/null) || true

  cfg=/etc/default/zramswap
  if [ -f "$cfg" ]; then
    cp -a "$cfg" "$cfg.bak-$STAMP"
    printf "  Backed up %s -> %s\n" "$cfg" "$cfg.bak-$STAMP"
  fi
  cat > "$cfg" <<'CFGHEAD'
# Managed by swap-setup. zstd gives the best ratio/speed on modern kernels;
# PRIORITY is high so the kernel fills compressed RAM before any disk swap file.
ALGO=zstd
PRIORITY=100
CFGHEAD
  printf 'PERCENT=%s\n' "$pct" >> "$cfg"

  systemctl enable "$unit" >/dev/null 2>&1 || true
  systemctl restart "$unit" >/dev/null 2>&1 || true
  # Device setup is asynchronous; poll briefly rather than trusting a single sleep.
  tries=0
  while [ "$tries" -lt 10 ]; do
    if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; then break; fi
    tries=$((tries + 1))
    sleep 1
  done

  if swapon --show=NAME --noheadings 2>/dev/null | grep -q '^/dev/zram'; then
    echo "  zram active at ${pct}% of RAM (priority 100)."
    echo "  With zram it is normal - and correct - to raise vm.swappiness to 100 (option 5)."
  else
    echo "  zram failed to come up. Rolling the config back."
    if [ -f "$cfg.bak-$STAMP" ]; then cp -a "$cfg.bak-$STAMP" "$cfg"; else rm -f "$cfg"; fi
    if [ "$was_enabled" != "enabled" ]; then
      # It was not enabled before we touched it; leaving it enabled would resurrect a
      # broken unit at every boot.
      systemctl disable "$unit" >/dev/null 2>&1 || true
    fi
    systemctl restart "$unit" >/dev/null 2>&1 || true
    echo "  Check: journalctl -u $unit -n 30"
  fi
}

# ------------------------------------------------------------- remove swap file
remove_swapfile() {
  local -a cands=()
  local p t sw i pick f ans mine dup old_keep new_keep
  if [ -s "$REG" ]; then
    while IFS= read -r p; do
      if [ -n "$p" ]; then cands+=("$p"); fi
    done < "$REG"
  fi
  # Also offer file-type swaps this tool did not create, but flag them - someone may have
  # configured them deliberately.
  sw=$(swapon --show=NAME,TYPE --noheadings 2>/dev/null) || true
  if [ -n "$sw" ]; then
    while read -r p t; do
      if [ "$t" != "file" ]; then continue; fi
      dup=0
      for i in "${cands[@]}"; do
        if [ "$i" = "$p" ]; then dup=1; fi
      done
      if [ "$dup" -eq 0 ]; then cands+=("$p"); fi
    done <<< "$sw"
  fi
  if [ "${#cands[@]}" -eq 0 ]; then
    echo "  No swap files to remove."
    return 0
  fi

  echo "  Swap files:"
  for i in "${!cands[@]}"; do
    f="${cands[$i]}"
    mine="unknown origin"
    if grep -qxF "$f" "$REG" 2>/dev/null; then mine="created by swap-setup"; fi
    printf "   %2d) %-30s %s\n" "$((i+1))" "$f" "$mine"
  done
  read -rp "  Number to remove (Enter = cancel): " pick || pick=""
  [ -z "$pick" ] && return 0
  printf '%s' "$pick" | grep -qE '^[0-9]+$' || { echo "  Not a number."; return 0; }
  if [ "$pick" -lt 1 ] || [ "$pick" -gt "${#cands[@]}" ]; then echo "  Out of range."; return 0; fi
  f="${cands[$((pick-1))]}"

  if swapoff_would_oom "$f"; then return 0; fi

  # Deleting the hibernation target turns the next "resume from disk" into a silent boot
  # into a fresh session, losing whatever was open.
  if grep -rqsF "$f" /etc/initramfs-tools/conf.d/ 2>/dev/null || grep -qsF "resume=$f" /proc/cmdline; then
    echo "  WARNING: $f is referenced by the hibernation/resume configuration."
    echo "  Removing it breaks resume-from-disk until that configuration is updated."
  fi

  echo
  echo "  This will swapoff $f, drop its $FSTAB entry and DELETE the file."
  if ! grep -qxF "$f" "$REG" 2>/dev/null; then
    echo "  NOTE: this tool did not create $f - someone configured it on purpose."
  fi
  read -rp "  Type YES to confirm: " ans || ans=""
  [ "$ans" = "YES" ] || { echo "  Cancelled."; return 0; }

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$f"; then
    if ! swapoff "$f"; then
      echo "  swapoff failed - the kernel still needs it. Nothing changed."
      return 0
    fi
  fi
  if awk -v p="$f" '$1==p && $3=="swap" {found=1} END {exit !found}' "$FSTAB"; then
    backup_fstab
    awk -v p="$f" '
      $1==p && $3=="swap" {next}
      $0=="# swap-setup: " p {next}
      index($0, "# swap-setup: " p " (")==1 {next}
      {print}
    ' "$FSTAB" > "$FSTAB.new"
    # Never install a truncated or over-pruned fstab: count the real (non-swap,
    # non-comment) mount lines and demand they all survived. An fstab missing / or /boot
    # is a box that does not come back from its next reboot.
    old_keep=$(awk '$3!="swap" && $0 !~ /^[[:space:]]*#/ && NF>0 {n++} END {printf "%d", n+0}' "$FSTAB") || true
    new_keep=$(awk '$3!="swap" && $0 !~ /^[[:space:]]*#/ && NF>0 {n++} END {printf "%d", n+0}' "$FSTAB.new") || true
    if [ -s "$FSTAB.new" ] && [ "${new_keep:-0}" = "${old_keep:-1}" ]; then
      cat "$FSTAB.new" > "$FSTAB"    # rewrite in place: keeps the inode, owner and mode
      rm -f "$FSTAB.new"
      echo "  Removed the $FSTAB entry."
    else
      rm -f "$FSTAB.new"
      echo "  Refused to rewrite $FSTAB - the result did not look right. The swap is off"
      echo "  and the file will be deleted; remove the stale line by hand (backup kept)."
    fi
  fi
  rm -f "$f"
  if [ -f "$REG" ]; then
    grep -vxF "$f" "$REG" > "$REG.new" 2>/dev/null || true
    if [ -f "$REG.new" ]; then
      cat "$REG.new" > "$REG"        # in place again, so the 600 mode is not replaced by 644
      rm -f "$REG.new"
    fi
  fi
  echo "  Removed $f."
}

# ------------------------------------------------------------------- sysctl tune
tune_sysctl() {
  local cur curvc ans sp vc conflicts
  cur=$(cat /proc/sys/vm/swappiness 2>/dev/null) || true
  curvc=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null) || true
  cur="${cur:-60}"
  curvc="${curvc:-100}"
  echo
  swappiness_note
  echo
  printf "  Current: swappiness=%s  vfs_cache_pressure=%s\n" "$cur" "$curvc"
  echo "    1) 10   - database / latency-sensitive server"
  echo "    2) 60   - kernel default, general purpose"
  echo "    3) 100  - box using zram (swapping to compressed RAM is cheap)"
  echo "    4) custom (0-100)"
  read -rp "  Choice (Enter = keep $cur): " ans || ans=""
  case "$ans" in
    "") sp="$cur" ;;
    1) sp=10 ;;
    2) sp=60 ;;
    3) sp=100 ;;
    4)
      read -rp "  swappiness 0-100: " sp || sp=""
      if ! printf '%s' "$sp" | grep -qE '^[0-9]+$'; then
        echo "  Must be a whole number 0-100."; return 0
      fi
      if [ "$sp" -gt 100 ]; then
        echo "  Must be a whole number 0-100."; return 0
      fi ;;
    *) echo "  Unknown choice."; return 0 ;;
  esac

  echo
  echo "  vfs_cache_pressure: how eagerly the kernel reclaims the dentry/inode caches."
  echo "  100 = default. 50 keeps directory metadata cached longer (good for file"
  echo "  servers and anything walking big trees). Below 10 risks memory pressure."
  read -rp "  vfs_cache_pressure 10-1000 [$curvc]: " vc || vc=""
  vc="${vc:-$curvc}"
  if ! printf '%s' "$vc" | grep -qE '^[0-9]+$'; then
    echo "  Must be a whole number 10-1000."; return 0
  fi
  if [ "$vc" -lt 10 ] || [ "$vc" -gt 1000 ]; then
    echo "  Must be a whole number 10-1000."; return 0
  fi

  # Apply live FIRST: if the running kernel rejects a value, we have not written a
  # sysctl.d file that would re-apply the bad value on every future boot.
  if ! sysctl -q -w vm.swappiness="$sp" 2>/dev/null; then
    echo "  Kernel rejected vm.swappiness=$sp. Nothing persisted."; return 0
  fi
  if ! sysctl -q -w vm.vfs_cache_pressure="$vc" 2>/dev/null; then
    sysctl -q -w vm.swappiness="$cur" 2>/dev/null || true
    echo "  Kernel rejected vm.vfs_cache_pressure=$vc. Rolled back, nothing persisted."; return 0
  fi
  if [ -f "$SYSCTLF" ]; then
    cp -a "$SYSCTLF" "$SYSCTLF.bak-$STAMP"
    printf "  Backed up %s -> %s\n" "$SYSCTLF" "$SYSCTLF.bak-$STAMP"
  fi
  cat > "$SYSCTLF" <<'SYSHEAD'
# Managed by swap-setup. /etc/sysctl.d/99-sysctl.conf is a symlink to /etc/sysctl.conf on
# Debian/Ubuntu and the drop-ins are applied in filename order, so this file is named
# 99-zz- to make sure it is the LAST word on these two knobs at boot.
SYSHEAD
  printf 'vm.swappiness = %s\nvm.vfs_cache_pressure = %s\n' "$sp" "$vc" >> "$SYSCTLF"
  printf "  Applied now and persisted in %s (swappiness=%s, vfs_cache_pressure=%s).\n" \
    "$SYSCTLF" "$sp" "$vc"

  # Two files setting the same knob is how a "why did my swappiness revert?" ticket is
  # born. We win on ordering, but the operator should know the other files exist.
  conflicts=$(grep -lsE '^[[:space:]]*vm\.(swappiness|vfs_cache_pressure)' \
    /etc/sysctl.conf /etc/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /run/sysctl.d/*.conf 2>/dev/null \
    | grep -vxF "$SYSCTLF" | sort -u) || true
  if [ -n "$conflicts" ]; then
    echo "  Note - these files also set one of these values (ours is applied last):"
    printf '%s\n' "$conflicts" | sed 's/^/    /'
  fi
}

# ------------------------------------------------------------------------ main
touch "$REG"
chmod 600 "$REG"

while true; do
  echo
  echo "  Swap / zram"
  show_state
  echo "   1) Show current swap, RAM and swappiness (refresh)"
  echo "   2) Add a swap FILE on disk"
  echo "   3) zram - compressed RAM swap (better on a small, slow-disk VPS)"
  echo "   4) Remove a swap file"
  echo "   5) Tune swappiness / vfs_cache_pressure"
  echo "   Enter) quit"
  read -rp "  Choice: " CHOICE || CHOICE=""
  case "$CHOICE" in
    "") echo "  Bye."; exit 0 ;;
    1) : ;;
    2) add_swapfile; read -rp "  [Enter] to continue " _ || true ;;
    3) setup_zram;   read -rp "  [Enter] to continue " _ || true ;;
    4) remove_swapfile; read -rp "  [Enter] to continue " _ || true ;;
    5) tune_sysctl;  read -rp "  [Enter] to continue " _ || true ;;
    *) echo "  Unknown choice." ;;
  esac
done
SCRIPT
chmod +x /usr/local/sbin/swap-setup
echo "Installed. Run:  sudo swap-setup"
EOF

sudo swap-setup