#!/usr/bin/env bash
sudo bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive
command -v xl2tpd >/dev/null || { apt-get update && apt-get install -y xl2tpd ppp iptables; }
mkdir -p /etc/l2tp-server /etc/xl2tpd /etc/ppp
chmod 700 /etc/l2tp-server

cat > /usr/local/sbin/l2tp-server <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

ENVF="/etc/l2tp-server/server.env"
SECRETS="/etc/ppp/chap-secrets"
SRVNAME="l2tpd"                 # must match 'name' in options.xl2tpd and col 2 of chap-secrets
SESSDIR="/run/l2tp-sessions"

setup_server() {
  local DEF_WAN
  DEF_WAN="$(ip -o -4 route show to default | awk '{print $5; exit}')"

  read -rp "WAN interface (the uplink to NAT out of) [$DEF_WAN]: " WAN_IF; WAN_IF="${WAN_IF:-$DEF_WAN}"
  read -rp "VPN subnet [10.8.0.0/24]: " SUBNET; SUBNET="${SUBNET:-10.8.0.0/24}"
  read -rp "DNS to hand to clients [1.1.1.1]: " DNS; DNS="${DNS:-1.1.1.1}"
  read -rp "IPsec preshared key (Enter for plain L2TP, no IPsec): " PSK

  local BASE; BASE="${SUBNET%.*}"
  LOCALIP="$BASE.1"
  IPRANGE="$BASE.10-$BASE.200"

  cat > "$ENVF" <<E
WAN_IF=$WAN_IF
SUBNET=$SUBNET
LOCALIP=$LOCALIP
IPRANGE=$IPRANGE
DNS=$DNS
IPSEC=$( [ -n "$PSK" ] && echo yes || echo no )
E
  chmod 600 "$ENVF"

  cat > /etc/xl2tpd/xl2tpd.conf <<CONF
[global]
port = 1701
$( [ -n "$PSK" ] && echo "ipsec saref = yes" )

[lns default]
ip range = $IPRANGE
local ip = $LOCALIP
require chap = yes
refuse pap = yes
require authentication = yes
name = $SRVNAME
ppp debug = no
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
CONF

  # We are the LNS here. Note for the other side: xl2tpd clients only send their first
  # L2TP control-channel HELLO after 60s of idle, so an LNS keepalive timeout under ~60s
  # (MikroTik's default is 30) kills healthy tunnels ~25s in. xl2tpd has no such timer —
  # the lcp-echo below is what detects a dead peer, and 30s x 4 gives it room to answer.
  cat > /etc/ppp/options.xl2tpd <<OPT
require-mschap-v2
refuse-pap
refuse-chap
refuse-mschap
name $SRVNAME
auth
noccp
mtu 1400
mru 1400
proxyarp
ms-dns $DNS
lcp-echo-interval 30
lcp-echo-failure 4
connect-delay 5000
OPT

  touch "$SECRETS"; chmod 600 "$SECRETS"

  # ── this box is the clients' router ───────────────────────────────────────────
  # Forward + NAT their traffic out of the WAN. Applied now and re-applied at boot,
  # so it survives a reboot without pulling in iptables-persistent.
  echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-l2tp-server.conf
  sysctl -q -w net.ipv4.ip_forward=1

  cat > /usr/local/sbin/l2tp-server-nat <<'NAT'
#!/bin/bash
# Idempotent: -C tests for the rule, and we only add what is missing.
. /etc/l2tp-server/server.env
sysctl -q -w net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s "$SUBNET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$WAN_IF" -j MASQUERADE
iptables -C FORWARD -s "$SUBNET" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -s "$SUBNET" -o "$WAN_IF" -j ACCEPT
iptables -C FORWARD -d "$SUBNET" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -d "$SUBNET" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# PPP links are MTU-limited; without this, big packets over the tunnel black-hole.
iptables -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
  iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
NAT
  chmod +x /usr/local/sbin/l2tp-server-nat

  cat > /etc/systemd/system/l2tp-server-nat.service <<UNIT
[Unit]
Description=L2TP server NAT/forwarding rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/l2tp-server-nat

[Install]
WantedBy=multi-user.target
UNIT

  # Session tracking: pppd runs these on every connect/disconnect, which is the only
  # reliable way to map a ppp interface back to the username that dialled it.
  mkdir -p /etc/ppp/ip-up.d /etc/ppp/ip-down.d
  cat > /etc/ppp/ip-up.d/l2tp-server <<'UP'
#!/bin/bash
# args: $1 iface  $2 tty  $3 speed  $4 local-ip  $5 remote-ip  $6 ipparam
mkdir -p /run/l2tp-sessions
{ echo "USER=${PEERNAME:-unknown}"; echo "IP=$5"; echo "SINCE=$(date +%s)"; } > "/run/l2tp-sessions/$1"
UP
  cat > /etc/ppp/ip-down.d/l2tp-server <<'DOWN'
#!/bin/bash
rm -f "/run/l2tp-sessions/$1"
DOWN
  chmod +x /etc/ppp/ip-up.d/l2tp-server /etc/ppp/ip-down.d/l2tp-server

  # ── optional IPsec ────────────────────────────────────────────────────────────
  if [ -n "$PSK" ]; then
    command -v ipsec >/dev/null || { echo "Installing strongswan..."; apt-get update && apt-get install -y strongswan >/dev/null; }
    touch /etc/ipsec.secrets; chmod 600 /etc/ipsec.secrets
    sed -i '/# l2tp-server/d' /etc/ipsec.secrets 2>/dev/null || true
    echo ": PSK \"$PSK\"  # l2tp-server" >> /etc/ipsec.secrets
    mkdir -p /etc/ipsec.d
    cat > /etc/ipsec.d/l2tp-server.conf <<IPSEC
conn l2tp-server
    keyexchange=ikev1
    authby=secret
    auto=add
    type=transport
    left=%any
    leftprotoport=17/1701
    right=%any
    rightprotoport=17/%any
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha1,aes128-sha1,3des-sha1!
IPSEC
    grep -q "^include /etc/ipsec.d/\*.conf" /etc/ipsec.conf 2>/dev/null || echo "include /etc/ipsec.d/*.conf" >> /etc/ipsec.conf
    ipsec restart 2>/dev/null || systemctl restart strongswan 2>/dev/null || true
  fi

  systemctl daemon-reload
  systemctl enable --now l2tp-server-nat.service >/dev/null 2>&1 || true
  systemctl enable xl2tpd >/dev/null 2>&1 || true
  systemctl restart xl2tpd

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active"; then
    ufw allow 1701/udp >/dev/null 2>&1 || true
    [ -n "$PSK" ] && { ufw allow 500/udp >/dev/null 2>&1; ufw allow 4500/udp >/dev/null 2>&1; }
    echo "  (opened the L2TP ports in ufw)"
  fi

  echo
  echo "L2TP server up. Clients get $IPRANGE and reach the internet through $WAN_IF."
  echo "IPsec: $( [ -n "$PSK" ] && echo "on (PSK set)" || echo "off — plain L2TP" )"
  echo "Add a user with option 2."
}

users_list() {
  mapfile -t USERS < <(awk -v s="$SRVNAME" '$2==s && $1 !~ /^#/ {print $1}' "$SECRETS" 2>/dev/null)
}

add_user() {
  [ -f "$ENVF" ] || { echo "Set the server up first (option 1)."; return 1; }
  . "$ENVF"
  read -rp "Username: " U
  [ -z "$U" ] && { echo "Username required."; return 1; }
  users_list
  printf '%s\n' "${USERS[@]}" | grep -qx "$U" && { echo "User '$U' already exists."; return 1; }
  while :; do read -rsp "Password: " P; echo; [ -n "$P" ] && break; echo "  Required."; done
  read -rp "Pin a fixed VPN IP (Enter = any from the pool): " FIXED

  printf '%s\t%s\t%s\t%s\n' "$U" "$SRVNAME" "$P" "${FIXED:-*}" >> "$SECRETS"
  chmod 600 "$SECRETS"
  echo
  echo "Added '$U'. Client settings:"
  echo "    Server:   $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this box public IP>')"
  echo "    Username: $U"
  echo "    IPsec:    $( [ "$IPSEC" = yes ] && echo "PSK required" || echo "none (plain L2TP)" )"
  echo "  No xl2tpd restart needed — pppd reads chap-secrets on each connect."
}

del_user() {
  users_list
  [ "${#USERS[@]}" -eq 0 ] && { echo "No users yet."; return; }
  echo "Users:"
  local i
  for i in "${!USERS[@]}"; do echo "  $((i+1))) ${USERS[$i]}"; done
  read -rp "Choose number: " C
  local T="${USERS[$((C-1))]}"
  [ -z "$T" ] && { echo "Invalid."; return; }
  read -rp "Really remove '$T'? [y/N]: " Y
  [ "$Y" != "y" ] && [ "$Y" != "Y" ] && { echo "Cancelled."; return; }

  # Only ever touch our own rows: username in col 1 AND our server name in col 2.
  awk -v u="$T" -v s="$SRVNAME" '!($1==u && $2==s)' "$SECRETS" > "$SECRETS.tmp"
  mv "$SECRETS.tmp" "$SECRETS"; chmod 600 "$SECRETS"

  # Kick them off if they are connected right now — deleting the secret alone only stops
  # the NEXT dial; the live pppd keeps the session up until it is killed.
  local f ifc pidf
  for f in "$SESSDIR"/*; do
    [ -e "$f" ] || continue
    ifc="$(basename "$f")"
    # subshell: sourcing the session file would clobber $USER in this shell
    if [ "$(. "$f"; echo "$USER")" = "$T" ]; then
      echo "  disconnecting live session on $ifc..."
      # pppd's pidfile name differs between ppp 2.4 (Ubuntu 22/24) and ppp 2.5
      # (Ubuntu 26) — try both layouts rather than assume one.
      for pidf in "/run/$ifc.pid" "/var/run/$ifc.pid" "/run/pppd-$ifc.pid" "/var/run/pppd-$ifc.pid"; do
        [ -f "$pidf" ] || continue
        kill "$(cat "$pidf")" 2>/dev/null || true
        break
      done
      rm -f "$f"
    fi
  done
  echo "Removed '$T'."
}

list_users() {
  users_list
  [ "${#USERS[@]}" -eq 0 ] && { echo "No users yet."; return; }
  declare -A ONLINE_IP ONLINE_SINCE ONLINE_IF
  local f now
  now="$(date +%s)"
  for f in "$SESSDIR"/*; do
    [ -e "$f" ] || continue
    ( . "$f"; echo "$USER|$IP|$SINCE|$(basename "$f")" )
  done > /tmp/.l2tp-sess.$$ 2>/dev/null || true
  while IFS='|' read -r u ip since ifc; do
    [ -n "$u" ] && { ONLINE_IP["$u"]="$ip"; ONLINE_SINCE["$u"]="$since"; ONLINE_IF["$u"]="$ifc"; }
  done < /tmp/.l2tp-sess.$$
  rm -f /tmp/.l2tp-sess.$$

  printf "%-16s %-9s %-13s %-8s %s\n" "USER" "STATE" "VPN IP" "IFACE" "UPTIME"
  local u up
  for u in "${USERS[@]}"; do
    if [ -n "${ONLINE_IP[$u]:-}" ]; then
      up=$(( now - ${ONLINE_SINCE[$u]:-$now} ))
      printf "%-16s %-9s %-13s %-8s %s\n" "$u" "ONLINE" "${ONLINE_IP[$u]}" "${ONLINE_IF[$u]}" "$((up/60))m $((up%60))s"
    else
      printf "%-16s %-9s %-13s %-8s %s\n" "$u" "offline" "-" "-" "-"
    fi
  done
}

show_user() {
  users_list
  [ "${#USERS[@]}" -eq 0 ] && { echo "No users yet."; return; }
  echo "Users:"
  local i
  for i in "${!USERS[@]}"; do echo "  $((i+1))) ${USERS[$i]}"; done
  read -rp "Choose number: " C
  local T="${USERS[$((C-1))]}"
  [ -z "$T" ] && { echo "Invalid."; return; }
  . "$ENVF"
  local PW FIXED
  PW="$(awk -v u="$T" -v s="$SRVNAME" '$1==u && $2==s {print $3; exit}' "$SECRETS")"
  FIXED="$(awk -v u="$T" -v s="$SRVNAME" '$1==u && $2==s {print $4; exit}' "$SECRETS")"
  echo "───────── $T ─────────"
  echo "Server:    $(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<this box public IP>')"
  echo "Username:  $T"
  echo "Password:  $PW"
  echo "IPsec:     $( [ "$IPSEC" = yes ] && echo "PSK required (see /etc/ipsec.secrets)" || echo "none (plain L2TP)" )"
  echo "VPN IP:    $( [ "$FIXED" = "*" ] && echo "from pool $IPRANGE" || echo "$FIXED (pinned)" )"
  echo "Gateway:   this server ($LOCALIP) — all client internet is NAT'd out of $WAN_IF"
  echo "──────────────────────"
}

echo "L2TP Server (LNS)"
echo "  1) Set up / reconfigure the server"
echo "  2) Add a user"
echo "  3) List users (online status)"
echo "  4) Show a user's connection details"
echo "  5) Remove a user"
echo "  6) Server status"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) setup_server ;;
  2) add_user ;;
  3) list_users ;;
  4) show_user ;;
  5) del_user ;;
  6) systemctl is-active xl2tpd >/dev/null 2>&1 && echo "xl2tpd: active" || echo "xl2tpd: inactive"
     ipsec status 2>/dev/null || true
     echo; echo "Live sessions:"; ls "$SESSDIR" 2>/dev/null || echo "  none"
     echo; ip -o -4 addr show 2>/dev/null | grep ppp || true ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
SCRIPT
chmod +x /usr/local/sbin/l2tp-server
echo "Installed. Run:  sudo l2tp-server"
EOF

sudo l2tp-server
