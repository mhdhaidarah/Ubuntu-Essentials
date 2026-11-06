#!/usr/bin/env bash
sudo bash <<'EOF'
need=""; for p in sysbench fio; do command -v "$p" >/dev/null 2>&1 || need="$need $p"; done
[ -n "$need" ] && { apt-get -o DPkg::Lock::Timeout=180 update -qq && apt-get -o DPkg::Lock::Timeout=180 install -y -qq $need >/dev/null; }

cat > /usr/local/sbin/perf-report <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# perf-report -- one-page performance scorecard of this server (~45 s).
#
#   perf-report          print it, and save a copy in /var/log/perf-report/
#
# Short versions of the CPU, memory and disk benchmarks plus the current state
# (load, memory, disk space, network, busiest processes), each graded, so two
# servers -- or the same server before/after a change -- compare at a glance.
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; DIM=$'\033[2m'; R=$'\033[0m'
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
OUTD=/var/log/perf-report; mkdir -p "$OUTD"; OUT="$OUTD/$(date +%F-%H%M).txt"
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "$OUT")) 2>&1
row() { printf '  %-22s %-34s %s\n' "$1" "$2" "$3"; }
g() { awk -v v="$1" -v a="$2" -v b="$3" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" 'BEGIN{ if (v>=a) print G "A" R; else if (v>=b) print Y "B" R; else print RD "C" R }'; }
gi() { awk -v v="$1" -v a="$2" -v b="$3" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" 'BEGIN{ if (v<=a) print G "A" R; else if (v<=b) print Y "B" R; else print RD "C" R }'; }
echo "${B}${CY}Performance report${R}  $(hostname)  $(date '+%F %H:%M %Z')"
echo "  $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//'), $(nproc) threads, $(awk '/MemTotal/{printf "%.1f GiB RAM", $2/1048576}' /proc/meminfo), $(lsb_release -ds 2>/dev/null), kernel $(uname -r)"
echo; printf '  %s%-22s %-34s %s%s\n' "$DIM" "check" "result" "grade" "$R"
E1=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time=5 run 2>/dev/null | awk '/events per second/{print $4}')
row "CPU, one core" "${E1} events/s" "$(g "${E1%.*}" 450 300)"
EN=$(sysbench cpu --cpu-max-prime=20000 --threads="$(nproc)" --time=5 run 2>/dev/null | awk '/events per second/{print $4}')
CO=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l); TH=$(nproc)
EFF=$(awk -v c="$CO" -v t="$TH" 'BEGIN{ if (c>0 && c<t) printf "%.2f", c+(t-c)*0.25; else printf "%d", t }')
row "CPU, all cores" "${EN} events/s" "$(g "$(awk -v a="${E1:-1}" -v b="${EN:-0}" -v e="$EFF" 'BEGIN{printf "%d", b/(a*e)*100}')" 85 65)"
MW=$(sysbench memory --memory-block-size=1M --memory-total-size=100G --threads="$(nproc)" --time=5 run 2>/dev/null | awk -F'[()]' '/transferred/{print $2}' | awk '{printf "%.0f", $1}')
row "Memory bandwidth" "${MW} MiB/s" "$(g "${MW:-0}" 20000 8000)"
F=/var/tmp/.perf-report.$$; trap 'rm -f "$F"' EXIT
IOPS=$(fio --name=r --filename="$F" --size=512M --direct=1 --ioengine=libaio --rw=randread --bs=4k --iodepth=32 --runtime=6 --time_based --output-format=terse --terse-version=3 2>/dev/null | awk -F';' '{printf "%d", $8}')
row "Disk random read" "${IOPS} IOPS (4K)" "$(g "${IOPS:-0}" 20000 3000)"
SY=$(fio --name=s --filename="$F" --size=32M --rw=write --bs=4k --fsync=1 --ioengine=sync --runtime=5 --time_based --output-format=terse --terse-version=3 2>/dev/null | awk -F';' '{printf "%d", $49}')
row "Disk commits (fsync)" "${SY} per second" "$(g "${SY:-0}" 1500 300)"
L1=$(cut -d' ' -f1 /proc/loadavg); LP=$(awk -v l="$L1" -v n="$(nproc)" 'BEGIN{printf "%d", l/n*100}')
row "Load (1 min)" "$L1 (${LP}% of cores)" "$(gi "$LP" 70 100)"
MA=$(awk '/MemAvailable/{a=$2} /MemTotal/{t=$2} END{printf "%d", a*100/t}' /proc/meminfo)
row "Memory available" "${MA}%" "$(g "$MA" 25 10)"
DU=$(df -P / | awk 'NR==2{print $5}' | tr -d %)
row "Root disk used" "${DU}%" "$(gi "$DU" 75 90)"
read -r _ a1 a2 a3 a4 a5 a6 a7 a8 _ < /proc/stat; sleep 2; read -r _ b1 b2 b3 b4 b5 b6 b7 b8 _ < /proc/stat
STL=$(awk -v s=$((b8-a8)) -v t=$(( (b1+b2+b3+b4+b5+b6+b7+b8)-(a1+a2+a3+a4+a5+a6+a7+a8) )) 'BEGIN{ if(t<1)t=1; printf "%.1f", s*100/t }')
row "CPU steal (VPS)" "${STL}%" "$(gi "${STL%.*}" 2 5)"
IF=$(ip route show default | awk '{print $5; exit}'); [ -n "$IF" ] && {
  read -r r1 t1 < <(awk -v i="$IF" -F'[: ]+' '$2==i{print $3, $11}' /proc/net/dev); sleep 1
  read -r r2 t2 < <(awk -v i="$IF" -F'[: ]+' '$2==i{print $3, $11}' /proc/net/dev)
  row "Traffic on $IF" "$(awk -v d=$((r2-r1)) -v u=$((t2-t1)) 'BEGIN{printf "down %.1f / up %.1f Mbit/s", d*8/1e6, u*8/1e6}')" "${DIM}now${R}"; }
row "TCP connections" "$(ss -Htan state established | wc -l) established" "${DIM}now${R}"
row "Failed services" "$(systemctl --failed --no-legend | wc -l)" "$( [ "$(systemctl --failed --no-legend | wc -l)" -eq 0 ] && echo "${G}A${R}" || echo "${RD}C${R}")"
echo; echo "  ${DIM}Busiest processes:${R}"
ps -eo pcpu,pmem,comm --sort=-pcpu --no-headers | head -5 | awk '{printf "    %5s%% CPU  %5s%% MEM  %s\n", $1, $2, $3}'
echo; echo "  ${DIM}A = good, B = acceptable, C = look at it. Saved: $OUT${R}"
SCRIPT
chmod +x /usr/local/sbin/perf-report
echo "Installed. Run:  sudo perf-report"
EOF

sudo perf-report
