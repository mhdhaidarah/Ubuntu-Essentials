#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/server-triage <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# ---------------------------------------------------------------------------
# server-triage -- READ-ONLY health triage.
#
# This tool NEVER writes, restarts, kills, installs or reconfigures anything.
# It is the first thing you run on a box you do not trust yet, and a box you
# do not trust yet is the worst possible place to have a side effect. Every
# command below is a reporting command; if you ever add one that mutates
# state, it belongs in a different snippet.
#
# It needs root only because journalctl (kernel + other units' logs) and
# `ss -p` (socket owner) hide most of their output from an unprivileged user,
# which is exactly the output that identifies the fault.
# ---------------------------------------------------------------------------

DISK_WARN=85          # percent full at which a filesystem gets flagged
MEM_WARN=10           # percent of RAM still available below which we complain

FINDINGS=()
note() { FINDINGS+=("$1"); }          # record something worth a human's attention

rule()  { printf '%s\n' "----------------------------------------------------------------------"; }
title() { echo; printf '== %s\n' "$1"; rule; }

# KiB -> short human string. Everything we read (/proc/meminfo, ps rss, df)
# is in KiB, so the unit ladder starts at K.
human_kb() {
  awk -v k="${1:-0}" 'BEGIN{ n=split("K,M,G,T,P",u,","); i=1;
    while (k>=1024 && i<n) { k/=1024; i++ }
    printf "%.1f%s", k, u[i] }'
}

# Numeric comparison helper: awk is the only thing on a base system that does
# float maths reliably ([ ] and (( )) are integer-only, and load averages and
# percentages are not integers).
gt() { awk -v a="$1" -v b="$2" 'BEGIN{ exit !(a > b) }'; }

HAVE_SYSTEMD=no
# /run/systemd/system exists only when systemd is actually PID 1. Checking for
# the systemctl binary is not enough: it is present inside many containers
# where every systemctl call then fails with "failed to connect to bus".
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  HAVE_SYSTEMD=yes
fi

# =========================== 1. SYSTEM / LOAD ==============================
sec_system() {
  title "SYSTEM"
  local host os kern up l1 l5 l15 cores rest
  host=$(hostname 2>/dev/null) || true
  os=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2) || true
  kern=$(uname -r) || true
  up=$(uptime -p 2>/dev/null) || true
  # /proc/uptime is the fallback because `uptime -p` is a procps extension and
  # a stripped image may not ship it, while /proc/uptime is always there.
  if [ -z "$up" ] && [ -r /proc/uptime ]; then
    up=$(awk '{ d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60);
                printf "up %dd %dh %dm", d, h, m }' /proc/uptime) || true
  fi

  read -r l1 l5 l15 rest < /proc/loadavg || true
  cores=$(nproc 2>/dev/null) || true
  cores=${cores:-1}

  printf "  %-14s %s\n" "Host:"   "${host:-?}"
  printf "  %-14s %s\n" "OS:"     "${os:-unknown}"
  printf "  %-14s %s\n" "Kernel:" "${kern:-?}"
  printf "  %-14s %s\n" "Uptime:" "${up:-unknown}"
  printf "  %-14s %s %s %s   (%s core(s))\n" "Load 1/5/15:" "$l1" "$l5" "$l15" "$cores"

  # Load average counts runnable AND uninterruptible-sleep tasks on Linux, so
  # a box blocked on dead storage shows a huge load with an idle CPU. That is
  # why the summary says "or blocked on I/O" rather than "CPU is busy".
  if gt "$l1" "$cores"; then
    printf "  %-14s load %s exceeds %s core(s)\n" "FLAG:" "$l1" "$cores"
    note "Load average $l1 is above the $cores core(s) this box has - something is saturating CPU or blocked on I/O (see the process list)."
  fi
  # A 15-minute average far below the 1-minute one means the problem started
  # just now; the reverse means it has been grinding for a while. Worth saying
  # out loud because it decides whether you look at logs or at a change made
  # this morning.
  if gt "$l1" "$cores" && gt "$l1" "$(awk -v x="$l15" 'BEGIN{print x*2}')"; then
    note "The load spike is recent (1-min average is more than double the 15-min one) - look for something that started in the last few minutes."
  fi

  if [ -f /var/run/reboot-required ]; then
    printf "  %-14s YES\n" "Reboot req:"
    if [ -s /var/run/reboot-required.pkgs ]; then
      local pkgs
      pkgs=$(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ') || true
      printf "  %-14s %s\n" "  asked by:" "$pkgs"
      note "A reboot is pending, requested by: $pkgs"
    else
      note "A reboot is pending (/var/run/reboot-required exists)."
    fi
  else
    printf "  %-14s no\n" "Reboot req:"
  fi

  # A kernel newer on disk than the running one is the same class of problem
  # as reboot-required, and it is the one that silently leaves known-exploited
  # kernels running for months.
  local newest
  newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1) || true
  if [ -n "$newest" ] && [ -n "$kern" ] && [ "$newest" != "$kern" ]; then
    printf "  %-14s running %s, installed %s\n" "Kernel:" "$kern" "$newest"
    note "Running kernel $kern is older than the installed $newest - the box has not been rebooted since the kernel update."
  fi
  return 0
}

# ============================== 2. MEMORY ==================================
sec_memory() {
  title "MEMORY"
  local mt ma st sf used_pct swap_used swap_pct
  mt=$(awk '/^MemTotal:/{print $2}'     /proc/meminfo) || true
  ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo) || true
  st=$(awk '/^SwapTotal:/{print $2}'    /proc/meminfo) || true
  sf=$(awk '/^SwapFree:/{print $2}'     /proc/meminfo) || true
  mt=${mt:-0}; ma=${ma:-0}; st=${st:-0}; sf=${sf:-0}

  # MemAvailable, not MemFree. MemFree on a healthy Linux box is always tiny
  # because the kernel spends spare RAM on page cache; people panic at it every
  # week. MemAvailable is the kernel's own estimate of what a new workload can
  # actually get, and it is the only number worth alarming on.
  used_pct=$(awk -v t="$mt" -v a="$ma" 'BEGIN{ if(t>0) printf "%.0f", (t-a)*100/t; else print 0 }') || true
  printf "  %-14s %8s total, %8s available  (%s%% in use)\n" \
         "RAM:" "$(human_kb "$mt")" "$(human_kb "$ma")" "$used_pct"

  if [ "$st" -eq 0 ]; then
    printf "  %-14s none configured\n" "Swap:"
    # No swap is a deliberate choice on some hosts, but on a small VPS it means
    # the OOM killer is the only back-pressure the kernel has: the first memory
    # spike kills a service outright instead of slowing down.
    note "No swap is configured - a memory spike goes straight to the OOM killer with no warning. Fine if deliberate, a real risk on a small VPS."
  else
    swap_used=$(( st - sf ))
    swap_pct=$(awk -v t="$st" -v u="$swap_used" 'BEGIN{ printf "%.0f", u*100/t }') || true
    printf "  %-14s %8s total, %8s used        (%s%%)\n" \
           "Swap:" "$(human_kb "$st")" "$(human_kb "$swap_used")" "$swap_pct"
    if [ "$swap_pct" -ge 50 ]; then
      note "Swap is ${swap_pct}% used - the box has been over its RAM budget; expect everything to feel slow."
    fi
  fi

  local avail_pct
  avail_pct=$(( 100 - used_pct ))
  if [ "$avail_pct" -lt "$MEM_WARN" ]; then
    note "Only ${avail_pct}% of RAM is available ($(human_kb "$ma") of $(human_kb "$mt")) - this box is about to start killing processes."
  fi
  return 0
}

# =============================== 3. DISK ===================================
# Pseudo and image filesystems are excluded on purpose:
#   squashfs  - every installed snap is a 100%-full read-only image. Reporting
#               those as "disk full" trains the operator to ignore the section.
#   overlay   - container root layers; they consume the host fs that already
#               appears in this list, so counting them double is noise.
#   tmpfs/... - RAM-backed, covered by the memory section.
skip_fstype() {
  case "$1" in
    squashfs|overlay|tmpfs|devtmpfs|ramfs|efivarfs|autofs|proc|sysfs|cgroup|cgroup2|\
    devpts|debugfs|tracefs|mqueue|hugetlbfs|pstore|binfmt_misc|configfs|securityfs|\
    fusectl|nsfs|iso9660|udf) return 0 ;;
    fuse.*) return 0 ;;
    *) return 1 ;;
  esac
}

sec_disk() {
  title "DISK"
  local -A IPCT=()
  local line fs type inodes iused ifree ipct mp
  # Inode usage is collected first and merged into the one table below, because
  # an inode-exhausted filesystem reports plenty of free space and fails every
  # write with ENOSPC - it looks exactly like "disk full" and is fixed by
  # deleting many small files, not big ones.
  while read -r fs type inodes iused ifree ipct mp; do
    [ -z "$mp" ] && continue
    IPCT["$mp"]="${ipct%\%}"
  done < <(df -PTi 2>/dev/null | tail -n +2) || true

  printf "  %-24s %-9s %6s %6s %5s %6s\n" "MOUNT" "TYPE" "SIZE" "USED" "USE%" "INODE%"
  local size used avail pct p ip flag
  while read -r fs type size used avail pct mp; do
    [ -z "$mp" ] && continue
    skip_fstype "$type" && continue
    p="${pct%\%}"
    ip="${IPCT[$mp]:-0}"
    flag=""
    [ -n "$p" ] && [ "$p" -ge "$DISK_WARN" ] && flag=" <== FULL"
    [ -n "$ip" ] && [ "$ip" -ge "$DISK_WARN" ] && flag="$flag <== INODES"
    printf "  %-24s %-9s %6s %6s %4s%% %5s%%%s\n" \
           "${mp:0:24}" "${type:0:9}" "$size" "$used" "$p" "$ip" "$flag"

    if [ -n "$p" ] && [ "$p" -ge "$DISK_WARN" ]; then
      note "Filesystem $mp is ${p}% full (${avail} free) - free space there before anything else."
    fi
    if [ -n "$ip" ] && [ "$ip" -ge "$DISK_WARN" ]; then
      note "Filesystem $mp has used ${ip}% of its INODES - writes will fail with 'No space left on device' even though df shows free space. Look for a directory with millions of small files (sessions, mail spool, cache)."
    fi

    # A filesystem the kernel remounted read-only did that because it hit an
    # I/O or metadata error. Every service that writes there is already broken
    # and no amount of restarting fixes it.
    if grep -qE "^[^ ]+ ${mp//\//\\/} [^ ]+ ro[, ]" /proc/mounts 2>/dev/null; then
      printf "  %-24s mounted READ-ONLY\n" "  ${mp:0:22}"
      note "Filesystem $mp is mounted READ-ONLY - the kernel did that after an I/O or filesystem error. Check the kernel messages and the disk before touching services."
    fi
  done < <(df -PTh 2>/dev/null | tail -n +2) || true
  return 0
}

# ============================= 4. PROCESSES ================================
sec_procs() {
  # ps %CPU is the average over the whole life of the process, not an
  # instantaneous reading: a daemon that pinned a core an hour ago still looks
  # busy, and a process that started 10 seconds ago can show 300%. Treat this
  # as "who to look at", then confirm with top before blaming anyone.
  title "TOP 5 BY CPU (%CPU is a lifetime average - confirm with top)"
  printf "  %7s %-10s %6s %8s  %s\n" "PID" "USER" "%CPU" "RSS" "COMMAND"
  local l p u c r a
  while read -r l; do
    [ -z "$l" ] && continue
    read -r p u c r a <<< "$l"
    printf "  %7s %-10s %5s%% %8s  %s\n" "$p" "${u:0:10}" "$c" "$(human_kb "$r")" "${a:0:34}"
  done < <(ps -eo pid=,user=,pcpu=,rss=,args= --sort=-pcpu 2>/dev/null | head -n 5) || true

  title "TOP 5 BY MEMORY (RSS)"
  printf "  %7s %-10s %6s %8s  %s\n" "PID" "USER" "%CPU" "RSS" "COMMAND"
  while read -r l; do
    [ -z "$l" ] && continue
    read -r p u c r a <<< "$l"
    printf "  %7s %-10s %5s%% %8s  %s\n" "$p" "${u:0:10}" "$c" "$(human_kb "$r")" "${a:0:34}"
  done < <(ps -eo pid=,user=,pcpu=,rss=,args= --sort=-rss 2>/dev/null | head -n 5) || true

  # Name the single biggest memory consumer in the summary when it owns a real
  # share of the machine - that is usually the answer to "why is it swapping".
  local top_rss top_cmd mt pct
  read -r top_rss top_cmd < <(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 1) || true
  mt=$(awk '/^MemTotal:/{print $2}' /proc/meminfo) || true
  if [ -n "${top_rss:-}" ] && [ -n "${mt:-}" ] && [ "$mt" -gt 0 ]; then
    pct=$(awk -v r="$top_rss" -v t="$mt" 'BEGIN{ printf "%.0f", r*100/t }') || true
    if [ "$pct" -ge 40 ]; then
      note "Process '$top_cmd' alone holds ${pct}% of RAM ($(human_kb "$top_rss")) - check whether that is its normal working set or a leak."
    fi
  fi
  return 0
}

# =========================== 5. FAILED UNITS ===============================
sec_units() {
  title "FAILED SYSTEMD UNITS"
  if [ "$HAVE_SYSTEMD" != "yes" ]; then
    printf "  systemd is not PID 1 here - skipping unit checks.\n"
    return 0
  fi
  local units u
  # --plain drops the bullet glyph, --no-legend drops the trailing summary, so
  # field 1 is the unit name and nothing else.
  mapfile -t units < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}') || true
  if [ "${#units[@]}" -eq 0 ]; then
    printf "  none\n"
    return 0
  fi
  for u in "${units[@]}"; do
    [ -z "$u" ] && continue
    local since
    since=$(systemctl show -p ExecMainExitTimestamp --value -- "$u" 2>/dev/null) || true
    printf "  %-38s failed %s\n" "${u:0:38}" "${since:-(time unknown)}"
  done
  note "${#units[@]} systemd unit(s) in the failed state: ${units[*]} - read 'systemctl status <unit>' and 'journalctl -u <unit> -n 50' for each."
  return 0
}

# ====================== 6. OOM KILLS / KERNEL ERRORS =======================
sec_kernel() {
  title "KERNEL: OOM KILLS AND I/O ERRORS"
  local kmsg=""
  # journalctl -k without -b spans every retained boot, which matters: the OOM
  # kill that explains today's outage often happened before the last reboot.
  # dmesg is the fallback for boxes with no persistent journal, but it only
  # holds the current boot's ring buffer.
  if command -v journalctl >/dev/null 2>&1; then
    kmsg=$(journalctl -k --no-pager -o short 2>/dev/null | tail -n 20000) || true
  fi
  if [ -z "$kmsg" ]; then
    kmsg=$(dmesg -T 2>/dev/null || dmesg 2>/dev/null) || true
  fi

  local oom victims n
  oom=$(printf '%s\n' "$kmsg" | grep -iE 'out of memory|oom-kill|oom_reaper' || true)
  if [ -n "$oom" ]; then
    n=$(printf '%s\n' "$oom" | grep -c . || true)
    printf "  %s OOM-related kernel line(s). Last 3:\n" "$n"
    printf '%s\n' "$oom" | tail -n 3 | cut -c1-200 | sed 's/^/    /'
    # Two message shapes exist depending on kernel version: the old
    # "Killed process 123 (name)" and the newer "oom-kill:...,task=name,...".
    # Pull the victim out of both so the summary can name it.
    victims=$( { printf '%s\n' "$oom" | grep -oE 'Killed process [0-9]+ \(([^)]+)\)' | sed 's/.*(\(.*\))/\1/';
                 printf '%s\n' "$oom" | grep -oE 'task=[^,]+' | cut -d= -f2; } \
               | sort | uniq -c | sort -rn | head -n 3 | awk '{printf "%s(x%s) ", $2, $1}') || true
    note "The kernel OOM killer has fired ${victims:+on: $victims}- the machine ran out of memory and killed processes. ${victims:+Those services died without a crash of their own.}"
  else
    printf "  no OOM kills found in the kernel log\n"
  fi

  local ioerr
  # These patterns are the ones that mean failing storage rather than a
  # noisy driver; a match here outranks every other finding on the screen.
  ioerr=$(printf '%s\n' "$kmsg" | grep -iE 'I/O error|EXT4-fs error|XFS \(.*\): (metadata )?I/O error|rejecting I/O to offline device|Buffer I/O error' || true)
  if [ -n "$ioerr" ]; then
    n=$(printf '%s\n' "$ioerr" | grep -c . || true)
    printf "  %s storage/filesystem error line(s). Last 3:\n" "$n"
    printf '%s\n' "$ioerr" | tail -n 3 | cut -c1-200 | sed 's/^/    /'
    note "The kernel logged $n storage/filesystem error(s) - suspect a failing disk or a detached volume BEFORE you blame any service. Check SMART and the hypervisor's disk."
  else
    printf "  no storage I/O errors in the kernel log\n"
  fi
  return 0
}

# ====================== 7. ERRORS IN THE LAST HOUR =========================
sec_errors() {
  title "ERRORS IN THE LAST HOUR (priority err and worse, by unit)"
  if ! command -v journalctl >/dev/null 2>&1; then
    printf "  journalctl not available - check /var/log/syslog by hand.\n"
    return 0
  fi
  local lines total
  # -o with-unit prints "<timestamp> <host> <unit>[<pid>]: <message>", so the
  # unit is the last token before the FIRST ": ". It has to be the first one:
  # messages routinely contain colons of their own. The timestamp's own colons
  # are safe because they are never followed by a space.
  #
  # The grep drops journalctl's own bracket lines ("-- No entries --",
  # "-- Boot abc123 --"). Without it an empty result counts as one error whose
  # unit parses out as "--", which is exactly the kind of confident nonsense a
  # triage tool must never print.
  mapfile -t lines < <(journalctl --since "1 hour ago" -p err --no-pager -o with-unit 2>/dev/null | grep -v '^-- ') || true
  total="${#lines[@]}"
  if [ "$total" -eq 0 ]; then
    printf "  none\n"
    return 0
  fi
  printf "  %s error line(s) in the last hour. Top units:\n" "$total"
  local counted u c sample
  counted=$(printf '%s\n' "${lines[@]}" \
            | sed 's/: /\x01/' | cut -d$'\001' -f1 \
            | awk '{print $NF}' \
            | sed 's/\[[0-9]*\]$//' \
            | sort | uniq -c | sort -rn | head -n 5) || true
  while read -r c u; do
    [ -z "$u" ] && continue
    # One example message per unit, because a count alone never tells you
    # whether it is a harmless repeat or the actual outage. grep needs -e here:
    # a unit name that starts with a dash would otherwise be eaten as an option.
    sample=$(printf '%s\n' "${lines[@]}" | grep -F -e "$u" | tail -n 1 \
             | sed 's/: /\x01/' | cut -d$'\001' -f2- | cut -c1-60) || true
    printf "  %6s x  %-26s %s\n" "$c" "${u:0:26}" "${sample:0:60}"
  done <<< "$counted"
  note "$total error-level log line(s) in the last hour; the loudest units are: $(printf '%s\n' "$counted" | awk '{printf "%s(%s) ", $2, $1}')"
  return 0
}

# ========================== 8. LISTENING PORTS =============================
sec_ports() {
  title "LISTENING TCP PORTS"
  if ! command -v ss >/dev/null 2>&1; then
    printf "  'ss' not available (install iproute2).\n"
    return 0
  fi
  printf "  %-30s %-22s %s\n" "LISTEN ON" "PROCESS" "PID"
  local addr proc pid line
  while read -r line; do
    [ -z "$line" ] && continue
    addr=$(printf '%s' "$line" | awk '{print $4}') || true
    proc=$(printf '%s' "$line" | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p') || true
    pid=$(printf '%s'  "$line" | sed -n 's/.*users:((\"[^\"]*\",pid=\([0-9]*\).*/\1/p') || true
    printf "  %-30s %-22s %s\n" "${addr:0:30}" "${proc:-?}" "${pid:-?}"
    # Sorted by port number, not by text: a plain sort puts 10022 before 22 and
    # scatters the IPv6 "[::]:22" rows away from their IPv4 twins. awk pulls the
    # port off as the last colon-separated piece of the address (which is what
    # makes it work for "[::]:80" and "127.0.0.53%lo:53" alike).
  done < <(ss -Hltnp 2>/dev/null | awk '{ n=split($4,a,":"); print a[n]"\t"$0 }' \
           | sort -n -k1,1 | cut -f2-) || true
  return 0
}

# ============================ 9. TIME SYNC =================================
sec_time() {
  title "TIME SYNC"
  local td tz sync ntp now
  now=$(date '+%Y-%m-%d %H:%M:%S %Z') || true
  printf "  %-14s %s\n" "Now:" "$now"
  if command -v timedatectl >/dev/null 2>&1; then
    td=$(timedatectl show 2>/dev/null) || true
    tz=$(printf   '%s\n' "$td" | sed -n 's/^Timezone=//p') || true
    sync=$(printf '%s\n' "$td" | sed -n 's/^NTPSynchronized=//p') || true
    ntp=$(printf  '%s\n' "$td" | sed -n 's/^NTP=//p') || true
    printf "  %-14s %s\n" "Timezone:" "${tz:-unknown}"
    printf "  %-14s %s\n" "NTP client:" "${ntp:-unknown}"
    printf "  %-14s %s\n" "Synchronized:" "${sync:-unknown}"
    # A clock that has drifted breaks TLS certificate validity windows, RADIUS
    # and Kerberos replay windows, and JWT expiry - all of which present as
    # "authentication randomly fails" and never as "the clock is wrong".
    if [ "$sync" = "no" ]; then
      note "The clock is NOT synchronized (NTPSynchronized=no). A wrong clock breaks TLS validation, RADIUS/Kerberos and token expiry, and it never says so - it just fails to authenticate."
    fi
    if [ "$ntp" = "no" ]; then
      note "No NTP client is enabled - the clock will drift. 'timedatectl set-ntp true' is the fix (not run here: this tool changes nothing)."
    fi
  else
    printf "  timedatectl not available.\n"
    # On a box without timedatectl, chrony/ntpd may still be doing the job.
    # NOTE the '|| true': `systemctl is-active` PRINTS "inactive" and EXITS
    # non-zero, which under `set -e` would kill this function mid-report.
    local svc st
    for svc in chrony chronyd ntp ntpsec systemd-timesyncd; do
      st=$(systemctl is-active "$svc" 2>/dev/null) || true
      # An explicit `if` rather than `[ ... ] && printf`: the loop's exit status
      # is that of its last command, so a final iteration whose test fails would
      # make the whole for-loop "fail" and `set -e` would abort the report here.
      if [ "$st" = "active" ]; then
        printf "  %-14s %s is active\n" "NTP:" "$svc"
      fi
    done
  fi
  return 0
}

# ============================== SUMMARY ====================================
sec_summary() {
  echo
  rule
  printf "  WHAT I WOULD LOOK AT FIRST\n"
  rule
  if [ "${#FINDINGS[@]}" -eq 0 ]; then
    printf "  Nothing stands out. Load is within the core count, memory and\n"
    printf "  disk have headroom, no failed units, no OOM kills, no errors in\n"
    printf "  the last hour and the clock is in sync.\n"
    printf "\n  If the box still misbehaves, the fault is above this layer:\n"
    printf "  application logs, an upstream network path, or the hypervisor.\n"
  else
    local i=1 f
    for f in "${FINDINGS[@]}"; do
      # fold keeps long findings readable on an 80-column console; the -s makes
      # it break on spaces instead of mid-word.
      printf '  %d. %s\n' "$i" "$f" | fold -s -w 70 | sed '2,$s/^/     /'
      i=$(( i + 1 ))
    done
  fi
  rule
  return 0
}

run_all() {
  FINDINGS=()
  echo
  printf "  SERVER TRIAGE  -  %s  -  read-only, nothing is changed\n" "$(date '+%Y-%m-%d %H:%M:%S')"
  sec_system
  sec_memory
  sec_disk
  sec_procs
  sec_units
  sec_kernel
  sec_errors
  sec_ports
  sec_time
  sec_summary
  return 0
}

run_all

# The menu is deliberately limited to further READ-ONLY detail views. Anything
# that would fix a finding lives in another tool, on purpose: triage and repair
# should never be one keystroke apart on a machine you have not understood yet.
while true; do
  echo
  echo "  1) re-run the triage"
  echo "  2) full error log for the last hour"
  echo "  3) all listening sockets (TCP and UDP)"
  echo "  4) full process list, biggest memory first"
  echo "  5) biggest directories on / (read-only scan, can take a minute)"
  echo "  6) recent kernel messages (last 40 lines)"
  echo "  Enter) quit"
  read -rp "Choice: " C
  case "${C:-}" in
    "")  echo "Bye."; exit 0 ;;
    1)   run_all ;;
    2)   journalctl --since "1 hour ago" -p err --no-pager -o short 2>/dev/null | tail -n 200 || true ;;
    3)   ss -tulpn 2>/dev/null || true ;;
    4)   ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-rss 2>/dev/null | head -n 40 || true ;;
    5)   echo "  Scanning / (one filesystem only, one level deep)..."
         # -x keeps the scan on the root filesystem: without it a du on a box
         # with network mounts wanders onto NFS/sshfs and hangs for minutes.
         du -x -d1 -m / 2>/dev/null | sort -nr | head -n 15 | awk '{printf "  %8s MB  %s\n", $1, $2}' || true ;;
    6)   { journalctl -k --no-pager -o short 2>/dev/null || dmesg -T 2>/dev/null; } | tail -n 40 || true ;;
    *)   echo "  Unknown choice." ;;
  esac
done
SCRIPT
chmod +x /usr/local/sbin/server-triage
echo "Installed. Run:  sudo server-triage"
EOF

sudo server-triage