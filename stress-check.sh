#!/usr/bin/env bash
sudo bash <<'EOF'
command -v stress-ng >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=180 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq stress-ng >/dev/null; }

cat > /usr/local/sbin/stress-check <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# stress-check -- is this machine stable under full load?
#
#   stress-check            60 s burn of CPU + RAM + disk
#   stress-check 300        five minutes (better before putting a box in service)
#
# Runs stress-ng with verification on (it checks its own results, so a faulty
# CPU/RAM shows up as errors, not just as slowness) and samples temperature,
# clock and load every 5 s. Uses at most 70% of available RAM and a 512 MiB
# scratch file in /var/tmp. Everything stops and is removed at the end.
# Do not run it on a production box during business hours.
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; DIM=$'\033[2m'; R=$'\033[0m'
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
D=${1:-60}; [[ "$D" =~ ^[0-9]+$ ]] || D=60
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
temp() { local t; t=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1); [ -n "$t" ] && echo "$((t/1000))°C" || echo "n/a"; }
mhz()  { awk -F: '/cpu MHz/{s+=$2; n++} END{if(n) printf "%.0f", s/n; else print "n/a"}' /proc/cpuinfo; }
AV=$(awk '/MemAvailable/{print int($2*0.7/1024)}' /proc/meminfo)
title "Stress test: ${D}s, $(nproc) CPU workers, ${AV} MiB RAM, 512 MiB disk"
echo "  Before: temperature $(temp), clock $(mhz) MHz, load $(cut -d' ' -f1 /proc/loadavg)"
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
stress-ng --cpu "$(nproc)" --cpu-method all --vm 2 --vm-bytes "${AV}M" --vm-method all \
          --hdd 1 --hdd-bytes 512M --temp-path /var/tmp --verify --timeout "${D}s" --metrics-brief >"$LOG" 2>&1 &
SP=$!
printf '  %s%6s %10s %10s %8s%s\n' "$DIM" "time" "temp" "clock" "load" "$R"
MAXT=0; MINF=999999; t=0
while kill -0 $SP 2>/dev/null; do
  sleep 5; t=$((t+5)); tc=$(temp); f=$(mhz)
  printf '  %5ss %10s %7s MHz %8s\n' "$t" "$tc" "$f" "$(cut -d' ' -f1 /proc/loadavg)"
  n=${tc%°C}; [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt "$MAXT" ] && MAXT=$n
  [[ "$f" =~ ^[0-9]+$ ]] && [ "$f" -lt "$MINF" ] && MINF=$f
done
wait $SP; RC=$?
title "Result"
# stress-ng prints "failed: N" (workers that failed their own checks) and "error" lines on real faults
ERR=$(( $(grep -oE 'failed: [0-9]+' "$LOG" | awk '{s+=$2} END{print s+0}') + $(grep -ciE 'stress-ng: (error|fail)' "$LOG") ))
grep -E '^stress-ng: (info|metrc).*(cpu|vm|hdd) ' "$LOG" | grep -vi 'skipped' | tail -4 | sed 's/^stress-ng: [a-z]*: *\[[0-9]*\] */  /'
[ "$MAXT" -gt 0 ] && echo "  Hottest: ${MAXT}°C"
if [ "$RC" -eq 0 ] && [ "${ERR:-0}" -eq 0 ]; then echo "  ${G}${B}Stable:${R} no errors under full load."
else echo "  ${RD}${B}Problems found${R} (exit $RC, $ERR error lines). Last lines:"; tail -5 "$LOG" | sed 's/^/    /'; fi
[ "$MAXT" -ge 90 ] && echo "  ${RD}Runs hot (>= 90°C): check cooling / dust / fan curve.${R}"
grep -qi throttl /var/log/kern.log 2>/dev/null && echo "  ${Y}The kernel logged thermal throttling.${R}"
SCRIPT
chmod +x /usr/local/sbin/stress-check
echo "Installed. Run:  sudo stress-check   (or: sudo stress-check 300)"
EOF

sudo stress-check
