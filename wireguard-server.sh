#!/usr/bin/env bash
sudo bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive
command -v wg >/dev/null || { apt-get update && apt-get install -y wireguard iptables; }
command -v qrencode >/dev/null || apt-get install -y qrencode >/dev/null 2>&1 || true
mkdir -p /etc/wireguard/clients
chmod 700 /etc/wireguard /etc/wireguard/clients

cat > /usr/local/sbin/wg-server <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

WGIF="wg0"
CONF="/etc/wireguard/$WGIF.conf"
CDIR="/etc/wireguard/clients"
ENVF="/etc/wireguard/server.env"

# ── peers are rebuilt from $CDIR, never hand-edited in place ───────────────────
# Each client's .conf is the source of truth: the server's public key for a peer is
# derived from the client's private key, so adding or removing one client can never
# corrupt the others' peer blocks.
rebuild_conf() {
  . "$ENVF"
  umask 077
  # Dual-stack: the server carries a ULA (fc10::1/64 by default) alongside its IPv4.
  # Most boxes get no delegated IPv6 prefix, so clients are NAT66'd out of the WAN just
  # like IPv4 — they get working IPv6 without the ISP handing us a prefix. SUBNET6 empty
  # ⇒ IPv4-only (v6 lines are simply omitted).
  local addr6line="" v6up="" v6down=""
  if [ -n "$SUBNET6" ]; then
    addr6line="Address = $SRV_IP6/64"
    v6up="PostUp   = sysctl -w net.ipv6.conf.all.forwarding=1
PostUp   = ip6tables -t nat -A POSTROUTING -s $SUBNET6 -o $WAN_IF -j MASQUERADE
PostUp   = ip6tables -A FORWARD -i $WGIF -o $WAN_IF -j ACCEPT
PostUp   = ip6tables -A FORWARD -i $WAN_IF -o $WGIF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    v6down="PostDown = ip6tables -t nat -D POSTROUTING -s $SUBNET6 -o $WAN_IF -j MASQUERADE
PostDown = ip6tables -D FORWARD -i $WGIF -o $WAN_IF -j ACCEPT
PostDown = ip6tables -D FORWARD -i $WAN_IF -o $WGIF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
  fi
  cat > "$CONF" <<IFACE
[Interface]
Address = $SRV_IP/24
${addr6line:+$addr6line}
ListenPort = $PORT
PrivateKey = $(cat /etc/wireguard/server_private.key)

# This box is the clients' router: forward their traffic and NAT it out of $WAN_IF.
PostUp   = sysctl -w net.ipv4.ip_forward=1
PostUp   = iptables -t nat -A POSTROUTING -s $SUBNET -o $WAN_IF -j MASQUERADE
PostUp   = iptables -A FORWARD -i $WGIF -o $WAN_IF -j ACCEPT
PostUp   = iptables -A FORWARD -i $WAN_IF -o $WGIF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -A FORWARD -p tcp --tcp-flags SYN,RST SYN -o $WAN_IF -j TCPMSS --clamp-mss-to-pmtu
${v6up:+$v6up}
PostDown = iptables -t nat -D POSTROUTING -s $SUBNET -o $WAN_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i $WGIF -o $WAN_IF -j ACCEPT
PostDown = iptables -D FORWARD -i $WAN_IF -o $WGIF -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -D FORWARD -p tcp --tcp-flags SYN,RST SYN -o $WAN_IF -j TCPMSS --clamp-mss-to-pmtu
${v6down:+$v6down}
IFACE

  local f name priv pub psk addr addr6
  for f in "$CDIR"/*.conf; do
    [ -e "$f" ] || continue
    name="$(basename "$f" .conf)"
    # Split on the FIRST '=' only: base64 keys are '='-padded, so a '='-delimited
    # field split would silently truncate the padding and produce an invalid key.
    priv="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
    # Address line is "10.7.0.5/24" or "10.7.0.5/24, fc10::5/64" — take v4 and v6 halves.
    addr="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$f" | head -1 | cut -d, -f1 | sed 's,/.*,,')"
    addr6="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$f" | head -1 | cut -d, -f2- | tr -d ' ' | sed 's,/.*,,')"
    pub="$(echo "$priv" | wg pubkey)"
    psk="$(cat "$CDIR/$name.psk" 2>/dev/null || true)"
    local allowed="$addr/32"
    [ -n "$SUBNET6" ] && [ -n "$addr6" ] && [ "$addr6" != "$addr" ] && allowed="$allowed, $addr6/128"
    {
      echo
      echo "### client $name"
      echo "[Peer]"
      echo "PublicKey = $pub"
      [ -n "$psk" ] && echo "PresharedKey = $psk"
      echo "AllowedIPs = $allowed"
    } >> "$CONF"
  done
  # wg-quick chokes on blank in-between lines from omitted v6 vars; squeeze them.
  sed -i '/^$/N;/^\n$/D' "$CONF"
  chmod 600 "$CONF"
}

# Apply the new peer set to the RUNNING interface without bouncing it —
# a wg-quick down/up here would drop every connected client.
apply() {
  if ip link show "$WGIF" >/dev/null 2>&1; then
    wg syncconf "$WGIF" <(wg-quick strip "$WGIF")
  else
    wg-quick up "$WGIF"
  fi
}

next_ip() {
  . "$ENVF"
  local base="${SRV_IP%.*}" i used
  for i in $(seq 2 254); do
    used=0
    grep -rhq "Address = $base.$i/" "$CDIR" 2>/dev/null && used=1
    [ "$used" = "0" ] && { echo "$base.$i"; return; }
  done
  echo "ERR"; return 1
}

setup_server() {
  local DEF_WAN DEF_EP
  DEF_WAN="$(ip -o -4 route show to default | awk '{print $5; exit}')"
  DEF_EP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

  read -rp "Public endpoint (IP or domain clients dial) [$DEF_EP]: " ENDPOINT; ENDPOINT="${ENDPOINT:-$DEF_EP}"
  [ -z "$ENDPOINT" ] && { echo "An endpoint is required."; return 1; }
  read -rp "WAN interface (the uplink to NAT out of) [$DEF_WAN]: " WAN_IF; WAN_IF="${WAN_IF:-$DEF_WAN}"
  read -rp "Listen port [51820]: " PORT; PORT="${PORT:-51820}"
  read -rp "VPN subnet [10.7.0.0/24]: " SUBNET; SUBNET="${SUBNET:-10.7.0.0/24}"
  # Dual-stack by default: a ULA prefix the clients get NAT66'd out of (no ISP prefix
  # needed). Enter 'none' for IPv4-only.
  read -rp "IPv6 ULA prefix (Enter=fc10::/64, or 'none'): " SUBNET6; SUBNET6="${SUBNET6:-fc10::/64}"
  [ "$SUBNET6" = "none" ] && SUBNET6=""
  read -rp "DNS to hand to clients [1.1.1.1]: " DNS; DNS="${DNS:-1.1.1.1}"
  SRV_IP="${SUBNET%.*}.1"
  local PREFIX6="" SRV_IP6=""
  if [ -n "$SUBNET6" ]; then
    PREFIX6="${SUBNET6%%/*}"        # fc10::/64 -> fc10::
    SRV_IP6="${PREFIX6}1"           # -> fc10::1
  fi

  [ -f /etc/wireguard/server_private.key ] || {
    umask 077
    wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
  }

  cat > "$ENVF" <<E
ENDPOINT=$ENDPOINT
WAN_IF=$WAN_IF
PORT=$PORT
SUBNET=$SUBNET
SRV_IP=$SRV_IP
SUBNET6=$SUBNET6
PREFIX6=$PREFIX6
SRV_IP6=$SRV_IP6
DNS=$DNS
E

  # Forwarding must also survive a reboot — PostUp only covers the wg-quick path.
  { echo "net.ipv4.ip_forward=1"; [ -n "$SUBNET6" ] && echo "net.ipv6.conf.all.forwarding=1"; } > /etc/sysctl.d/99-wireguard.conf
  sysctl -q -w net.ipv4.ip_forward=1
  [ -n "$SUBNET6" ] && sysctl -q -w net.ipv6.conf.all.forwarding=1

  rebuild_conf
  systemctl enable "wg-quick@$WGIF" >/dev/null 2>&1 || true
  systemctl restart "wg-quick@$WGIF"

  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "^Status: active" && {
    ufw allow "$PORT"/udp >/dev/null 2>&1 || true
    ufw route allow in on "$WGIF" out on "$WAN_IF" >/dev/null 2>&1 || true
    echo "  (opened $PORT/udp in ufw)"
  }

  echo
  echo "Server up on $ENDPOINT:$PORT — clients get $SUBNET$([ -n "$SUBNET6" ] && echo " + $SUBNET6") and route the internet through $WAN_IF."
  [ -n "$SUBNET6" ] && echo "IPv6: dual-stack on, clients NAT66'd out of $WAN_IF (server $SRV_IP6)."
  echo "Server public key: $(cat /etc/wireguard/server_public.key)"
}

add_client() {
  [ -f "$ENVF" ] || { echo "Set the server up first (option 1)."; return 1; }
  . "$ENVF"
  read -rp "Client name: " NAME
  [ -z "$NAME" ] && { echo "Name required."; return 1; }
  NAME="${NAME// /_}"
  [ -f "$CDIR/$NAME.conf" ] && { echo "Client '$NAME' already exists."; return 1; }

  read -rp "Route ALL of this client's traffic through the server (full tunnel)? [Y/n]: " FT
  if [ "$FT" = "n" ] || [ "$FT" = "N" ]; then ALLOWED="$SUBNET"; else ALLOWED="0.0.0.0/0, ::/0"; fi

  local IP PRIV PUB PSK octet IP6 addrline
  IP="$(next_ip)"; [ "$IP" = "ERR" ] && { echo "Subnet full."; return 1; }
  octet="${IP##*.}"
  addrline="$IP/24"
  # Dual-stack: same host number in the ULA (10.7.0.5 -> fc10::5), so v4 and v6 line up.
  if [ -n "$SUBNET6" ]; then IP6="${PREFIX6}${octet}"; addrline="$IP/24, $IP6/64"; fi
  umask 077
  PRIV="$(wg genkey)"; PUB="$(echo "$PRIV" | wg pubkey)"; PSK="$(wg genpsk)"
  echo "$PSK" > "$CDIR/$NAME.psk"

  cat > "$CDIR/$NAME.conf" <<C
[Interface]
PrivateKey = $PRIV
Address = $addrline
DNS = $DNS

[Peer]
PublicKey = $(cat /etc/wireguard/server_public.key)
PresharedKey = $PSK
Endpoint = $ENDPOINT:$PORT
AllowedIPs = $ALLOWED
PersistentKeepalive = 25
C
  chmod 600 "$CDIR/$NAME.conf"

  rebuild_conf
  apply
  echo
  echo "Added '$NAME' at $IP  (peer $PUB)"
  echo
  show_client "$NAME"
}

show_client() {
  local NAME="${1:-}"
  if [ -z "$NAME" ]; then
    pick_client || return 1
    NAME="$PICKED"
  fi
  [ -f "$CDIR/$NAME.conf" ] || { echo "No such client: $NAME"; return 1; }
  echo "───────── $NAME.conf ─────────"
  cat "$CDIR/$NAME.conf"
  echo "──────────────────────────────"
  if command -v qrencode >/dev/null; then
    echo "Scan with the WireGuard phone app:"
    qrencode -t ansiutf8 < "$CDIR/$NAME.conf"
  fi
  connect_snippet "$NAME"
}

# Offer a ready-to-paste snippet the OTHER side runs to connect back — so you don't have
# to hand-translate the .conf into router or server commands. The .conf itself is the
# source of truth; everything here is parsed from it.
connect_snippet() {
  local NAME="$1" f="$CDIR/$1.conf"
  # first '=' split only — base64 keys are '='-padded (a naive split truncates them).
  local priv addr dns spub psk endpoint allowed
  priv="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  addr="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  dns="$(sed -n 's/^DNS[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  spub="$(sed -n 's/^PublicKey[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  psk="$(sed -n 's/^PresharedKey[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  endpoint="$(sed -n 's/^Endpoint[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  allowed="$(sed -n 's/^AllowedIPs[[:space:]]*=[[:space:]]*//p' "$f" | head -1)"
  local ehost="${endpoint%:*}" eport="${endpoint##*:}"
  # Address may be "10.7.0.5/24" or dual-stack "10.7.0.5/24, fc10::5/64".
  local a4 a6
  a4="$(echo "$addr" | cut -d, -f1 | tr -d ' ')"                 # 10.7.0.5/24
  a6="$(echo "$addr" | cut -d, -f2- | tr -d ' ')"                # fc10::5/64  (empty if v4-only)
  [ "$a6" = "$a4" ] && a6=""
  # RouterOS wants the allowed-address list comma-joined with no spaces.
  local allowed_mt="${allowed// /}"

  echo
  read -rp "Print a ready-to-paste connect snippet for the client? [1] MikroTik  [2] Ubuntu  [Enter] skip: " WANT
  case "$WANT" in
    1)
      echo
      echo "═══ MikroTik — paste into the client router's terminal ═══"
      cat <<MT
/interface wireguard add name=wg-securytik private-key="$priv" mtu=1420
/ip address add address=$a4 interface=wg-securytik
/interface wireguard peers add interface=wg-securytik \\
    public-key="$spub" preshared-key="$psk" \\
    endpoint-address=$ehost endpoint-port=$eport \\
    allowed-address=$allowed_mt persistent-keepalive=25s
MT
      [ -n "$a6" ] && echo "/ipv6 address add address=$a6 interface=wg-securytik advertise=no"
      # Full-tunnel needs a default route + NAT the router can't safely guess; flag it.
      case "$allowed" in
        *0.0.0.0/0*) echo "# Full tunnel: also route traffic out of wg-securytik, e.g." ;
                     echo "#   /ip route add dst-address=0.0.0.0/0 gateway=wg-securytik" ;
                     echo "#   /ip firewall nat add chain=srcnat out-interface=wg-securytik action=masquerade" ;
                     [ -n "$a6" ] && echo "#   /ipv6 route add dst-address=::/0 gateway=wg-securytik" ;;
      esac
      echo "═════════════════════════════════════════════════════════"
      ;;
    2)
      echo
      echo "═══ Ubuntu — paste into the client's shell (installs WireGuard if missing) ═══"
      cat <<UB
sudo bash -c '
export DEBIAN_FRONTEND=noninteractive
command -v wg >/dev/null || { apt-get update && apt-get install -y wireguard; }
umask 077; mkdir -p /etc/wireguard
cat > /etc/wireguard/wg-securytik.conf <<WGCONF
[Interface]
PrivateKey = $priv
Address = $addr
DNS = $dns
[Peer]
PublicKey = $spub
PresharedKey = $psk
Endpoint = $endpoint
AllowedIPs = $allowed
PersistentKeepalive = 25
WGCONF
systemctl enable --now wg-quick@wg-securytik
sleep 2; wg show wg-securytik
'
UB
      echo "════════════════════════════════════════════════════════════════════════════"
      ;;
    *) : ;;
  esac
}

pick_client() {
  mapfile -t CL < <(ls "$CDIR"/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
  [ "${#CL[@]}" -eq 0 ] && { echo "No clients yet."; return 1; }
  echo "Clients:"
  local i
  for i in "${!CL[@]}"; do echo "  $((i+1))) ${CL[$i]}"; done
  read -rp "Choose number: " C
  PICKED="${CL[$((C-1))]}"
  [ -z "$PICKED" ] && { echo "Invalid."; return 1; }
  return 0
}

list_clients() {
  mapfile -t CL < <(ls "$CDIR"/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
  [ "${#CL[@]}" -eq 0 ] && { echo "No clients yet."; return; }
  local now name priv pub addr hs delta rx tx state
  now="$(date +%s)"
  printf "%-16s %-13s %-9s %-11s %s\n" "CLIENT" "VPN IP" "STATE" "HANDSHAKE" "TRANSFER (rx/tx)"
  for name in "${CL[@]}"; do
    priv="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' "$CDIR/$name.conf" | head -1)"
    pub="$(echo "$priv" | wg pubkey)"
    addr="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' "$CDIR/$name.conf" | head -1 | cut -d, -f1 | cut -d/ -f1)"
    hs="$(wg show "$WGIF" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1==k{print $2; exit}')"
    hs="${hs:-0}"
    rx="$(wg show "$WGIF" transfer 2>/dev/null | awk -v k="$pub" '$1==k{print $2; exit}')"
    tx="$(wg show "$WGIF" transfer 2>/dev/null | awk -v k="$pub" '$1==k{print $3; exit}')"
    if [ "$hs" -gt 0 ]; then
      delta=$(( now - hs ))
      # WireGuard rekeys about every 2 min; a handshake inside 3 min means the peer is live.
      if [ "$delta" -lt 180 ]; then state="ONLINE"; else state="offline"; fi
      printf "%-16s %-13s %-9s %-11s %s / %s\n" "$name" "$addr" "$state" "${delta}s ago" \
        "$(numfmt --to=iec ${rx:-0} 2>/dev/null || echo ${rx:-0})" \
        "$(numfmt --to=iec ${tx:-0} 2>/dev/null || echo ${tx:-0})"
    else
      printf "%-16s %-13s %-9s %-11s %s\n" "$name" "$addr" "never" "-" "-"
    fi
  done
}

del_client() {
  pick_client || return 1
  read -rp "Really remove '$PICKED'? [y/N]: " C
  [ "$C" != "y" ] && [ "$C" != "Y" ] && { echo "Cancelled."; return; }
  rm -f "$CDIR/$PICKED.conf" "$CDIR/$PICKED.psk"
  rebuild_conf
  apply
  echo "Removed '$PICKED'. The other clients stayed connected."
}

echo "WireGuard Server"
echo "  1) Set up / reconfigure the server"
echo "  2) Add a client"
echo "  3) List clients (online status)"
echo "  4) Show a client's config (+ QR)"
echo "  5) Remove a client"
echo "  6) Server status"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) setup_server ;;
  2) add_client ;;
  3) list_clients ;;
  4) show_client ;;
  5) del_client ;;
  6) wg show "$WGIF" 2>/dev/null || echo "$WGIF is down"; echo
     systemctl is-active "wg-quick@$WGIF" >/dev/null 2>&1 && echo "wg-quick@$WGIF: active" || echo "wg-quick@$WGIF: inactive" ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
SCRIPT
chmod +x /usr/local/sbin/wg-server
echo "Installed. Run:  sudo wg-server"
EOF

sudo wg-server
