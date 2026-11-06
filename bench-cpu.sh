#!/usr/bin/env bash
sudo bash <<'EOF'
command -v sysbench >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=180 update -qq && apt-get -o DPkg::Lock::Timeout=180 install -y -qq sysbench >/dev/null; }

cat > /usr/local/sbin/bench-cpu <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# bench-cpu -- how fast is this CPU, and is it really yours?
#
#   bench-cpu            full run (about 30 s)
#   bench-cpu quick      5 s per test
#
# 1. what the CPU is (model, cores, threads, clock, governor, virtualisation)
# 2. single-core and all-core speed (sysbench prime test, the same test the
#    internet quotes, so the numbers compare with other servers)
# 3. steal time: on a VPS, the share of CPU the host gave to someone else
# 4. throttling: the clock dropping under load (heat or power limit)
# Nothing is changed on the system; sysbench only computes primes.
# ---------------------------------------------------------------------------
B=$'\033[1m'; DIM=$'\033[2m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; R=$'\033[0m'
T=10; [ "${1:-}" = "quick" ] && T=5
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
kv()    { printf '  %-22s %s\n' "$1" "$2"; }
grade() { # value good ok -> coloured word
  awk -v v="$1" -v g="$2" -v o="$3" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" \
    'BEGIN{ if (v>=g) printf "%sfast%s", G, R; else if (v>=o) printf "%sok%s", Y, R; else printf "%sslow%s", RD, R }'
}

title "CPU"
MODEL=$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')
[ -z "$MODEL" ] && MODEL=$(lscpu 2>/dev/null | awk -F: '/Model name/{print $2; exit}' | sed 's/^ *//')
THREADS=$(nproc)
CORES=$(lscpu -p=CORE 2>/dev/null | grep -v '^#' | sort -u | wc -l)
MHZ=$(awk -F: '/cpu MHz/{s+=$2; n++} END{if(n) printf "%.0f MHz (now, average)", s/n}' /proc/cpuinfo)
GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a (VM or fixed clock)")
VIRT=$(systemd-detect-virt 2>/dev/null || echo none)
kv "Model" "${MODEL:-unknown}"
kv "Cores / threads" "${CORES:-?} / $THREADS"
kv "Clock" "${MHZ:-n/a}"
kv "Governor" "$GOV"
kv "Virtualisation" "$VIRT"
kv "Load (1/5/15 min)" "$(cut -d' ' -f1-3 /proc/loadavg)"

# steal + iowait over 3 s, from /proc/stat (user nice system idle iowait irq softirq steal)
read -r _ a1 a2 a3 a4 a5 a6 a7 a8 _ < /proc/stat; sleep 3
read -r _ b1 b2 b3 b4 b5 b6 b7 b8 _ < /proc/stat
TOT=$(( (b1+b2+b3+b4+b5+b6+b7+b8) - (a1+a2+a3+a4+a5+a6+a7+a8) )); [ "$TOT" -le 0 ] && TOT=1
STEAL=$(awk -v s=$((b8-a8)) -v t=$TOT 'BEGIN{printf "%.1f", s*100/t}')
BUSY=$(awk -v i=$((b4-a4)) -v t=$TOT 'BEGIN{printf "%.0f", 100-i*100/t}')
kv "CPU busy right now" "${BUSY}%"
if awk -v s="$STEAL" 'BEGIN{exit !(s>=5)}'; then
  kv "Steal time" "${RD}${STEAL}%${R}  the host is giving your CPU time to other VMs"
else
  kv "Steal time" "${G}${STEAL}%${R}"
fi

run() { sysbench cpu --cpu-max-prime=20000 --threads="$1" --time="$T" run 2>/dev/null; }
title "Single core (${T} s)"
OUT1=$(run 1)
E1=$(awk '/events per second/{print $4}' <<<"$OUT1"); L1=$(awk '/95th percentile/{print $3}' <<<"$OUT1")
kv "Events per second" "${B}${E1}${R}  ($(grade "${E1:-0}" 450 300))"
kv "Latency p95" "${L1} ms"

title "All $THREADS threads (${T} s)"
F0=$(awk -F: '/cpu MHz/{s+=$2; n++} END{if(n) printf "%.0f", s/n}' /proc/cpuinfo)
OUTN=$(run "$THREADS")
F1=$(awk -F: '/cpu MHz/{s+=$2; n++} END{if(n) printf "%.0f", s/n}' /proc/cpuinfo)
EN=$(awk '/events per second/{print $4}' <<<"$OUTN"); LN=$(awk '/95th percentile/{print $3}' <<<"$OUTN")
MAXL=$(awk '/max:/{print $2; exit}' <<<"$OUTN")
# What the hardware can deliver: every physical core counts 1, a hyper-thread sibling ~0.25 (it shares the core).
EFF=$(awk -v c="${CORES:-0}" -v t="$THREADS" 'BEGIN{ if (c>0 && c<t) printf "%.2f", c+(t-c)*0.25; else printf "%d", t }')
SCALE=$(awk -v a="${E1:-1}" -v b="${EN:-0}" -v e="$EFF" 'BEGIN{ if(a>0) printf "%.0f", b/(a*e)*100 }')
kv "Events per second" "${B}${EN}${R}"
kv "Latency p95 / max" "${LN} ms / ${MAXL} ms"
if [ "${CORES:-0}" -gt 0 ] && [ "$CORES" -lt "$THREADS" ]; then SCN="of what $CORES cores + $((THREADS-CORES)) hyper-threads give"; else SCN="of ${THREADS} x single-core"; fi
kv "Scaling" "${SCALE}% ${SCN}  ($(grade "${SCALE:-0}" 85 65))"
[ -n "$F0" ] && [ -n "$F1" ] && kv "Clock idle -> load" "${F0} -> ${F1} MHz"

title "Verdict"
awk -v e="${E1:-0}" -v s="${SCALE:-0}" -v st="$STEAL" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" 'BEGIN{
  if (e>=450) print "  " G "Single core: fast" R " (modern desktop / Ryzen / recent Xeon class)";
  else if (e>=300) print "  " Y "Single core: average" R " (typical VPS)";
  else print "  " RD "Single core: slow" R " (old or heavily shared CPU)";
  if (s<65) print "  " RD "Threads do not scale:" R " the extra vCPUs are shared or throttled";
  if (st>=5) print "  " RD "High steal:" R " ask your provider, or move to a dedicated-CPU plan";
  print "  " "Reference: Ryzen 9 7950X ~ 700/core, Xeon Gold ~ 400-500/core, entry VPS ~ 250-350/core."
}'
SCRIPT
chmod +x /usr/local/sbin/bench-cpu
echo "Installed. Run:  bench-cpu   (or: bench-cpu quick)"
EOF

bench-cpu
