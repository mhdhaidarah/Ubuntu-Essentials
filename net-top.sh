#!/usr/bin/env bash
sudo bash <<'EOF'
need=""; for p in iftop nethogs vnstat conntrack; do command -v "$p" >/dev/null 2>&1 || need="$need $p"; done
[ -n "$need" ] && { apt-get -o DPkg::Lock::Timeout=180 update -qq && DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=180 install -y -qq $need >/dev/null; }
systemctl enable --now vnstat >/dev/null 2>&1 || true

cat > /usr/local/sbin/net-top <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# net-top -- who is using the network right now.
#
#   net-top            menu
#   net-top 1..7       open one view directly (e.g. net-top 3)
#
# 1 live rates per interface (from the kernel counters, no extra tool)
# 2 top talkers: which remote IPs move the most traffic (iftop, 10 s sample)
# 3 bandwidth per process (nethogs, 10 s sample)
# 4 connections per remote IP (catches floods and scanners)
# 5 listening ports and the program behind each one
# 6 traffic history: today, this month, last 24 hours (vnStat)
# 7 tracked connections by state (conntrack / NAT table)
# Read-only: nothing is blocked, killed or changed.
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; DIM=$'\033[2m'; R=$'\033[0m'
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
DEFIF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
rate() { awk -v b="$1" 'BEGIN{ b*=8; u="bit/s"; if(b>=1e9){b/=1e9;u="Gbit/s"} else if(b>=1e6){b/=1e6;u="Mbit/s"} else if(b>=1e3){b/=1e3;u="kbit/s"}; printf "%7.1f %s", b, u }'; }

v_rates() {
  title "Live rates per interface (Ctrl-C to stop; 5 samples, 1 s apart)"
  for n in 1 2 3 4 5; do
    declare -A rx tx
    while read -r i r t; do rx[$i]=$r; tx[$i]=$t; done < <(awk -F'[: ]+' 'NR>2{print $2, $3, $11}' /proc/net/dev)
    sleep 1
    printf '  %s%-14s %18s %18s%s\n' "$DIM" "interface" "download" "upload" "$R"
    while read -r i r t; do
      [ "$i" = lo ] && continue
      d=$(( r - ${rx[$i]:-$r} )); u=$(( t - ${tx[$i]:-$t} ))
      [ $d -eq 0 ] && [ $u -eq 0 ] && [ "$i" != "$DEFIF" ] && continue
      mark=""; [ "$i" = "$DEFIF" ] && mark=" ${G}(default)${R}"
      printf '  %-14s %18s %18s%s\n' "$i" "$(rate $d)" "$(rate $u)" "$mark"
    done < <(awk -F'[: ]+' 'NR>2{print $2, $3, $11}' /proc/net/dev)
    [ $n -lt 5 ] && echo
    unset rx tx
  done
}
v_talkers() {
  local IF=${1:-$DEFIF}
  title "Top talkers on $IF (10 s sample)"
  iftop -i "$IF" -t -s 10 -n -N -P -L 15 2>/dev/null | sed -n '/^   #/,/^====/p' | sed 's/^/  /' | head -40
  echo "  ${DIM}Each pair: this server => remote (sent) / <= (received), rates for the last 2s, 10s, 40s.${R}"
}
v_procs() {
  title "Bandwidth per process (10 s sample)"
  printf '  %s%-40s %14s %14s%s\n' "$DIM" "program / pid / user" "sent KB/s" "received KB/s" "$R"
  # nethogs -t prints "program/pid/uid<TAB>sent<TAB>received" per refresh, plus start-up chatter: keep only real rows
  timeout 12 nethogs -t -c 10 -d 1 2>/dev/null | awk -F'\t' 'NF==3 && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ && $1 !~ /^unknown/ {last[$1]=$0} END{for(k in last) print last[k]}' \
    | sort -t$'\t' -k3 -nr | head -15 | awk -F'\t' '{printf "  %-40s %14.1f %14.1f\n", substr($1,1,40), $2, $3}'
}
v_conns() {
  title "Connections per remote IP (TCP + UDP)"
  ss -Htun state established 2>/dev/null | awk '{print $6}' | sed -E 's/:[0-9]+$//; s/^\[|\]$//g' | sort | uniq -c | sort -nr | head -15 \
    | awk -v RD="$RD" -v R="$R" '{c=($1>=100)? RD : ""; printf "  %s%6d%s  %s\n", c, $1, R, $2}'
  echo "  ${DIM}Hundreds from one IP usually means a flood, a scanner or a stuck client.${R}"
  echo; echo "  States: $(ss -Htan 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -nr | awk '{printf "%s %s  ", $2, $1}')"
}
v_ports() {
  title "Listening ports"
  ss -Htulpn 2>/dev/null | awk '{split($7,p,"\""); a=$5; printf "  %-5s %-28s %s\n", $1, a, (p[2]!=""?p[2]:"-")}' | sort -k2 -u
}
v_history() {
  title "Traffic history (vnStat${DEFIF:+, $DEFIF})"
  if vnstat -i "$DEFIF" --oneline >/dev/null 2>&1; then
    vnstat -i "$DEFIF" -d 7 2>/dev/null | sed 's/^/  /'; echo; vnstat -i "$DEFIF" -m 3 2>/dev/null | sed 's/^/  /'
  else echo "  vnStat has just started counting; come back in a few minutes for history."; fi
}
v_conntrack() {
  title "Tracked connections (conntrack)"
  if [ -r /proc/sys/net/netfilter/nf_conntrack_count ]; then
    c=$(cat /proc/sys/net/netfilter/nf_conntrack_count); mx=$(cat /proc/sys/net/netfilter/nf_conntrack_max)
    pct=$(( c*100/mx )); col=$G; [ $pct -ge 80 ] && col=$RD
    printf '  %-22s %s%s / %s (%s%%)%s\n' "In use / maximum" "$col" "$c" "$mx" "$pct" "$R"
    conntrack -L 2>/dev/null | awk '{print $1, ($4 ~ /=/ ? "-" : $4)}' | sort | uniq -c | sort -nr | head -8 | awk '{printf "  %6d  %s %s\n", $1, $2, $3}'
  else echo "  Connection tracking is not loaded (no firewall/NAT rules use it)."; fi
}
pick() { case "$1" in 1) v_rates;; 2) v_talkers;; 3) v_procs;; 4) v_conns;; 5) v_ports;; 6) v_history;; 7) v_conntrack;; *) return 1;; esac; }
[ -n "${1:-}" ] && { pick "$1"; exit; }
while true; do
  echo; echo "${B}net-top${R} ${DIM}(default interface: ${DEFIF:-none})${R}"
  echo "  1) live rates per interface      5) listening ports + programs"
  echo "  2) top talkers by IP             6) traffic history (day / month)"
  echo "  3) bandwidth per process         7) tracked connections (NAT)"
  echo "  4) connections per remote IP     Enter) quit"
  read -rp "Choice: " C; [ -z "$C" ] && exit 0; pick "$C" || echo "  Unknown choice."
done
SCRIPT
chmod +x /usr/local/sbin/net-top
echo "Installed. Run:  sudo net-top"
EOF

sudo net-top
