#!/usr/bin/env bash
sudo bash <<'EOF'
command -v sysbench >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=180 update -qq && apt-get -o DPkg::Lock::Timeout=180 install -y -qq sysbench >/dev/null; }

cat > /usr/local/sbin/bench-ram <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# bench-ram -- memory: how much is really free, how fast it is, who uses it.
#
#   bench-ram          state + bandwidth tests (about 25 s)
#
# Bandwidth is measured with sysbench memory (sequential write and read,
# 1 MiB blocks, all threads) and a random-access pass that feels like real
# server work (many small reads). Nothing is changed on the system.
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; R=$'\033[0m'
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
kv()    { printf '  %-24s %s\n' "$1" "$2"; }
mi()    { awk -v k="$1" 'BEGIN{ printf (k>=1048576 ? "%.1f GiB" : "%.0f MiB"), (k>=1048576 ? k/1048576 : k/1024) }'; }
m()     { awk -v k="$1" '$1==k":"{print $2}' /proc/meminfo; }

title "Memory now"
TOT=$(m MemTotal); AV=$(m MemAvailable); BUF=$(( $(m Buffers) + $(m Cached) )); ST=$(m SwapTotal); SF=$(m SwapFree)
PCT=$(( AV*100/TOT ))
kv "Total" "$(mi "$TOT")"
if [ "$PCT" -lt 10 ]; then kv "Available" "${RD}$(mi "$AV") (${PCT}%)${R}  memory pressure"; else kv "Available" "${G}$(mi "$AV") (${PCT}%)${R}"; fi
kv "Cache (reclaimable)" "$(mi "$BUF")"
if [ "${ST:-0}" -gt 0 ]; then kv "Swap used" "$(mi $((ST-SF))) of $(mi "$ST")"; else kv "Swap" "none"; fi
kv "Swappiness" "$(cat /proc/sys/vm/swappiness)"
ZR=$(cat /sys/block/zram0/disksize 2>/dev/null); [ -n "$ZR" ] && [ "$ZR" != 0 ] && kv "zram" "$(mi $((ZR/1024)))"
PSI=$(awk '/^some/{print $2}' /proc/pressure/memory 2>/dev/null | cut -d= -f2)
[ -n "$PSI" ] && kv "Memory stall (10 s avg)" "${PSI}%  (time tasks waited for memory)"

title "Bandwidth (sysbench, all $(nproc) threads)"
bw() { sysbench memory --memory-block-size="$1" --memory-total-size=100G --memory-oper="$2" \
         --memory-access-mode="$3" --threads="$(nproc)" --time=6 run 2>/dev/null \
       | awk -F'[()]' '/transferred/{print $2}' | awk '{printf "%.0f", $1}'; }
W=$(bw 1M write seq); RDD=$(bw 1M read seq); RND=$(bw 4K read rnd)
kv "Sequential write" "${B}${W} MiB/s${R}"
kv "Sequential read" "${B}${RDD} MiB/s${R}"
kv "Random 4K read" "${B}${RND} MiB/s${R}"

title "Biggest memory users"
ps -eo rss=,pid=,comm= --sort=-rss | head -8 | while read -r rss pid c; do printf '  %10s  %6s  %s\n' "$(mi "$rss")" "$pid" "$c"; done

title "Out-of-memory kills (since boot)"
OOM=$(journalctl -k --no-pager -q 2>/dev/null | grep -ci 'killed process' || true)
if [ "${OOM:-0}" -gt 0 ]; then
  kv "Kills" "${RD}${OOM}${R}"; journalctl -k --no-pager -q 2>/dev/null | grep -i 'killed process' | tail -3 | sed 's/^/  /'
else kv "Kills" "${G}none${R}"; fi

title "Verdict"
awk -v w="${W:-0}" -v p="$PCT" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" 'BEGIN{
  if (w>=20000) print "  " G "Memory is fast" R " (DDR4/DDR5 server class)";
  else if (w>=8000) print "  " Y "Memory is average" R " (shared VPS)";
  else print "  " RD "Memory is slow" R " (old host or heavy contention)";
  if (p<10) print "  " RD "Little memory left:" R " add RAM or swap (Swap / zram tool), or stop the top users above";
}'
SCRIPT
chmod +x /usr/local/sbin/bench-ram
echo "Installed. Run:  bench-ram"
EOF

bench-ram
