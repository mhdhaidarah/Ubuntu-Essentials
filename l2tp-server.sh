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
  # Dual-stack by default: a ULA prefix the clients get NAT66'd out of (no ISP prefix
  # needed). Enter 'none' for IPv4-only.
  read -rp "IPv6 ULA prefix (Enter=fc11::/64, or 'none'): " SUBNET6; SUBNET6="${SUBNET6:-fc11::/64}"
  [ "$SUBNET6" = "none" ] && SUBNET6=""
  read -rp "DNS to hand to clients [1.1.1.1]: " DNS; DNS="${DNS:-1.1.1.1}"
  read -rp "IPsec preshared key (Enter for plain L2TP, no IPsec): " PSK

  local BASE; BASE="${SUBNET%.*}"
  LOCALIP="$BASE.1"
  IPRANGE="$BASE.10-$BASE.200"
  local PREFIX6="" SRV_IP6=""
  if [ -n "$SUBNET6" ]; then PREFIX6="${SUBNET6%%/*}"; SRV_IP6="${PREFIX6}1"; fi

  cat > "$ENVF" <<E
WAN_IF=$WAN_IF
SUBNET=$SUBNET
LOCALIP=$LOCALIP
IPRANGE=$IPRANGE
SUBNET6=$SUBNET6
PREFIX6=$PREFIX6
SRV_IP6=$SRV_IP6
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
$( [ -n "$SUBNET6" ] && printf '+ipv6\nipv6cp-accept-local\nipv6cp-accept-remote' )
OPT

  touch "$SECRETS"; chmod 600 "$SECRETS"

  # ── this box is the clients' router ───────────────────────────────────────────
  # Forward + NAT their traffic out of the WAN. Applied now and re-applied at boot,
  # so it survives a reboot without pulling in iptables-persistent.
  { echo "net.ipv4.ip_forward=1"; [ -n "$SUBNET6" ] && echo "net.ipv6.conf.all.forwarding=1"; } > /etc/sysctl.d/99-l2tp-server.conf
  sysctl -q -w net.ipv4.ip_forward=1
  [ -n "$SUBNET6" ] && sysctl -q -w net.ipv6.conf.all.forwarding=1

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

# Dual-stack: same story over IPv6 — clients live in a ULA and are NAT66'd out (no ISP
# prefix delegation needed). Per-session client routes are added by the ppp ip-up hook.
if [ -n "$SUBNET6" ]; then
  sysctl -q -w net.ipv6.conf.all.forwarding=1
  ip6tables -t nat -C POSTROUTING -s "$SUBNET6" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    ip6tables -t nat -A POSTROUTING -s "$SUBNET6" -o "$WAN_IF" -j MASQUERADE
  ip6tables -C FORWARD -s "$SUBNET6" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
    ip6tables -A FORWARD -s "$SUBNET6" -o "$WAN_IF" -j ACCEPT
  ip6tables -C FORWARD -d "$SUBNET6" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    ip6tables -A FORWARD -d "$SUBNET6" -i "$WAN_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
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

# Dual-stack: give the client a global ULA derived from its IPv4 host number
# (10.8.0.10 -> fc11::10) and route it back over this ppp link; NAT66 (set by
# l2tp-server-nat) rewrites the source out of the WAN. The client configures the
# matching fc11::<n>/64 + default v6 route itself — see the connect snippet.
. /etc/l2tp-server/server.env 2>/dev/null
if [ -n "$SUBNET6" ]; then
  octet="${5##*.}"
  ip -6 route replace "${PREFIX6}${octet}/128" dev "$1" 2>/dev/null || true
  echo "IP6=${PREFIX6}${octet}" >> "/run/l2tp-sessions/$1"
fi
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
  [ -n "$SUBNET6" ] && echo "    IPv6:     dual-stack (ULA $SUBNET6, NAT66)"
  echo "  No xl2tpd restart needed — pppd reads chap-secrets on each connect."
  connect_snippet "$U" "$P" "${FIXED:-*}"
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
  [ -n "$SUBNET6" ] && echo "IPv6:      dual-stack on (ULA $SUBNET6, NAT66 out $WAN_IF)"
  echo "──────────────────────"
  connect_snippet "$T" "$PW" "$FIXED"
}

# Offer a ready-to-paste snippet the CLIENT runs to dial this server — so the far side
# doesn't hand-build the L2TP config. $1 user, $2 password, $3 pinned-v4-or-'*'.
connect_snippet() {
  local U="$1" P="$2" FIXED="$3"
  . "$ENVF"
  local SRV; SRV="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo '<server-public-ip>')"
  local PSKVAL=""; [ "$IPSEC" = yes ] && PSKVAL="$(sed -n 's/^: PSK "\(.*\)".*# l2tp-server/\1/p' /etc/ipsec.secrets 2>/dev/null | head -1)"
  # Client v6 is derived from the pinned v4 host number; pool users get it per-session.
  local V6=""; [ -n "$SUBNET6" ] && [ "$FIXED" != "*" ] && [ -n "$FIXED" ] && V6="${PREFIX6}${FIXED##*.}"

  echo
  read -rp "Print a ready-to-paste connect snippet for the client? [1] MikroTik  [2] Ubuntu  [Enter] skip: " WANT
  case "$WANT" in
    1)
      echo
      echo "═══ MikroTik — paste into the client router's terminal ═══"
      if [ "$IPSEC" = yes ]; then
        echo "/interface l2tp-client add name=l2tp-securytik connect-to=$SRV \\"
        echo "    user=$U password=$P use-ipsec=yes ipsec-secret=\"${PSKVAL:-<PSK>}\" \\"
        echo "    profile=default-encryption add-default-route=yes disabled=no"
      else
        echo "/interface l2tp-client add name=l2tp-securytik connect-to=$SRV \\"
        echo "    user=$U password=$P add-default-route=yes disabled=no"
      fi
      if [ -n "$SUBNET6" ]; then
        [ -n "$V6" ] && echo "/ipv6 address add address=$V6/64 interface=l2tp-securytik advertise=no" \
                     || echo "# IPv6: pin this user to a fixed IP to get a stable v6; then fc11::<host>"
        echo "/ipv6 route add dst-address=::/0 gateway=l2tp-securytik"
      fi
      echo "═════════════════════════════════════════════════════════"
      ;;
    2)
      echo
      echo "═══ Ubuntu — paste into the client's shell (installs xl2tpd if missing) ═══"
      cat <<UB
sudo bash -c '
export DEBIAN_FRONTEND=noninteractive
command -v xl2tpd >/dev/null || { apt-get update && apt-get install -y xl2tpd ppp; }
systemctl disable --now xl2tpd 2>/dev/null
mkdir -p /etc/xl2tpd /etc/ppp
cat > /etc/xl2tpd/xl2tpd.conf <<XL
[lac securytik]
lns = $SRV
ppp debug = no
pppoptfile = /etc/ppp/options.l2tpd.securytik
length bit = yes
redial = yes
redial timeout = 10
max redials = 65535
XL
cat > /etc/ppp/options.l2tpd.securytik <<PP
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
mtu 1400
mru 1400
noipdefault
defaultroute
replacedefaultroute
usepeerdns
persist
maxfail 0
holdoff 5
lcp-echo-interval 10
lcp-echo-failure 6
name "$U"
password "$P"
PP
chmod 600 /etc/ppp/options.l2tpd.securytik
systemctl enable --now xl2tpd
sleep 2; echo "c securytik" > /var/run/xl2tpd/l2tp-control
sleep 6; ip -4 addr show | grep ppp || echo "no ppp yet — check journalctl -u xl2tpd"
'
UB
      [ -n "$SUBNET6" ] && echo "# IPv6 over the tunnel is served by the server (ULA + NAT66); on Ubuntu the ppp" \
        && echo "# link is IPv4-transported — add the v6 addr after connect if you need it:" \
        && echo "#   sudo ip -6 addr add ${V6:-${PREFIX6}<host>}/64 dev ppp0 && sudo ip -6 route add default dev ppp0"
      echo "════════════════════════════════════════════════════════════════════════════"
      ;;
    *) : ;;
  esac
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
