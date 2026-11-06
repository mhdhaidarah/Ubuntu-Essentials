#!/usr/bin/env bash
sudo bash <<'EOF'
command -v iperf3 >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=180 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq iperf3 >/dev/null; }

cat > /usr/local/sbin/bench-net <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# bench-net -- real throughput between two of YOUR machines (iperf3).
#
#   bench-net server            listen on TCP/UDP 5201 until Ctrl-C
#   bench-net <server-ip>       run the tests against that server
#
# A speed test to the internet measures the provider; this measures the link
# you care about: office <-> server, two sites over a VPN, a new uplink.
# Tests: TCP upload, TCP download (reverse), 4 parallel streams, and UDP at a
# target rate with jitter and loss (what voice/video feel).
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; DIM=$'\033[2m'; R=$'\033[0m'
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
kv()    { printf '  %-26s %s\n' "$1" "$2"; }
case "${1:-}" in
  ""|-h|--help) sed -n 3,12p "$0" | sed 's/^# \{0,1\}/  /'; exit 0 ;;
  server)
    echo "Listening on TCP+UDP 5201. On the other machine run:  bench-net $(hostname -I | awk '{print $1}')"
    command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q active && echo "${Y}ufw is active: allow it with  ufw allow 5201${R}"
    exec iperf3 -s ;;
esac
S=$1; T=${2:-8}
mb() { awk -v b="$1" 'BEGIN{printf "%.1f Mbit/s", b/1e6}'; }
j() { iperf3 -c "$S" -t "$T" -J "$@" 2>/dev/null; }
title "Path to $S"
P=$(ping -c 5 -q "$S" 2>/dev/null | awk -F/ '/rtt/{print $5" ms average, "$7" ms jitter"}')
kv "Ping" "${P:-no reply (ICMP may be blocked)}"
iperf3 -c "$S" -t 1 >/dev/null 2>&1 || { echo "${RD}No iperf3 server on $S:5201. Run  bench-net server  there first.${R}"; exit 1; }

title "TCP (${T} s each)"
UP=$(j | python3 -c 'import json,sys; d=json.load(sys.stdin)["end"]; print(d["sum_sent"]["bits_per_second"], d["sum_sent"].get("retransmits",0))')
DN=$(j -R | python3 -c 'import json,sys; d=json.load(sys.stdin)["end"]; print(d["sum_received"]["bits_per_second"])')
PA=$(j -P 4 | python3 -c 'import json,sys; d=json.load(sys.stdin)["end"]; print(d["sum_received"]["bits_per_second"])')
kv "Upload (this -> server)" "${B}$(mb "${UP% *}")${R}  ${DIM}retransmits ${UP#* }${R}"
kv "Download (server -> this)" "${B}$(mb "$DN")${R}"
kv "4 parallel streams" "${B}$(mb "$PA")${R}"

title "UDP at 50 Mbit/s (${T} s) -- voice/video quality"
U=$(j -u -b 50M | python3 -c 'import json,sys; d=json.load(sys.stdin)["end"]["sum"]; print(d["jitter_ms"], d["lost_percent"], d["bits_per_second"])')
read -r JIT LOSS UBW <<<"$U"
kv "Delivered" "$(mb "$UBW")"
kv "Jitter" "$(printf '%.2f' "$JIT") ms"
col=$G; awk -v l="$LOSS" 'BEGIN{exit !(l>1)}' && col=$RD
kv "Loss" "${col}$(printf '%.2f' "$LOSS")%${R}"

title "Verdict"
awk -v up="${UP% *}" -v pa="$PA" -v l="$LOSS" -v jt="$JIT" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" 'BEGIN{
  if (pa > up*1.5) print "  " Y "Parallel streams are much faster than one:" R " latency or a per-flow limit caps single downloads (raise TCP buffers, or it is the VPN)";
  if (l>1) print "  " RD "UDP loss above 1%:" R " calls and video will break up on this path";
  else if (jt>30) print "  " Y "High jitter:" R " voice may sound choppy";
  else print "  " G "Path is clean for voice/video." R;
}'
SCRIPT
chmod +x /usr/local/sbin/bench-net
echo "Installed. On one machine: bench-net server     On the other: bench-net <that-ip>"
EOF
