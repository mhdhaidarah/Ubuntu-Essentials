#!/usr/bin/env bash
sudo bash <<'EOF'
command -v wg >/dev/null || { apt-get update && apt-get install -y wireguard; }
mkdir -p /etc/wireguard
chmod 700 /etc/wireguard

cat > /usr/local/sbin/wg-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

add_conn() {
  read -rp "Tunnel name [wg0]: " NAME; NAME="${NAME:-wg0}"
  CONF="/etc/wireguard/$NAME.conf"
  [ -f "$CONF" ] && { echo "$NAME already exists. Remove it first."; exit 1; }

  echo
  echo "Paste your client private key (or Enter to generate a new keypair):"
  read -rp "Private key: " PRIV
  if [ -z "$PRIV" ]; then
    PRIV=$(wg genkey)
    PUB=$(echo "$PRIV" | wg pubkey)
    echo ">> Generated. Give this PUBLIC key to the server admin:"
    echo "   $PUB"
  fi

  read -rp "Client address (e.g. 10.0.0.2/24): " ADDR
  read -rp "DNS (optional, e.g. 1.1.1.1, Enter to skip): " DNS
  read -rp "Server public key: " SPUB
  read -rp "Server endpoint (host:port, e.g. vpn.example.com:51820): " ENDPOINT
  read -rp "Allowed IPs [0.0.0.0/0, ::/0]: " ALLOWED; ALLOWED="${ALLOWED:-0.0.0.0/0, ::/0}"
  read -rp "Preshared key (optional, Enter to skip): " PSK
  read -rp "PersistentKeepalive seconds [25, Enter to skip]: " KA

  {
    echo "[Interface]"
    echo "PrivateKey = $PRIV"
    echo "Address = $ADDR"
    [ -n "$DNS" ] && echo "DNS = $DNS"
    echo
    echo "[Peer]"
    echo "PublicKey = $SPUB"
    [ -n "$PSK" ] && echo "PresharedKey = $PSK"
    echo "Endpoint = $ENDPOINT"
    echo "AllowedIPs = $ALLOWED"
    [ -n "$KA" ] && echo "PersistentKeepalive = $KA"
  } > "$CONF"
  chmod 600 "$CONF"

  systemctl enable --now "wg-quick@$NAME.service"
  echo
  echo "Done. Tunnel=$NAME"
  echo "Check: wg show | systemctl status wg-quick@$NAME"
}

list_conns() {
  mapfile -t CONNS < <(ls /etc/wireguard/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
}

# Force a reconnect from the stored config. WireGuard is stateless and silent: if the
# server was rebuilt, the endpoint's IP moved, or the link wedged, the tunnel just sits
# there looking "up" with no handshake. A down/up re-reads the .conf and re-resolves the
# endpoint DNS, which a plain 'systemctl restart' of a dead interface does not guarantee.
reconnect_conn() {
  list_conns
  [ "${#CONNS[@]}" -eq 0 ] && { echo "No WireGuard tunnels found."; return; }
  echo "Existing tunnels:"
  for i in "${!CONNS[@]}"; do echo "  $((i+1))) ${CONNS[$i]}"; done
  echo "  a) reconnect ALL"
  read -rp "Choose number (or 'a'): " C
  if [ "$C" = "a" ]; then TARGETS=("${CONNS[@]}")
  else T="${CONNS[$((C-1))]}"; [ -z "$T" ] && { echo "Invalid choice"; return; }; TARGETS=("$T"); fi

  for NAME in "${TARGETS[@]}"; do
    echo "Reconnecting $NAME..."
    wg-quick down "$NAME" 2>/dev/null || true
    sleep 1
    wg-quick up "$NAME" || { echo "  failed to bring $NAME up — check /etc/wireguard/$NAME.conf"; continue; }
    sleep 2
    HS="$(wg show "$NAME" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
    if [ -n "$HS" ] && [ "$HS" -gt 0 ]; then
      echo "  $NAME up — handshake $(( $(date +%s) - HS ))s ago."
    else
      echo "  $NAME up, but no handshake yet. Endpoint reachable? UDP port open? Keys right?"
    fi
  done
}

remove_conn() {
  list_conns
  [ "${#CONNS[@]}" -eq 0 ] && { echo "No WireGuard tunnels found."; return; }
  echo "Existing tunnels:"
  for i in "${!CONNS[@]}"; do echo "  $((i+1))) ${CONNS[$i]}"; done
  echo "  a) remove ALL"
  read -rp "Choose number (or 'a'): " C

  if [ "$C" = "a" ]; then
    TARGETS=("${CONNS[@]}")
  else
    T="${CONNS[$((C-1))]}"
    [ -z "$T" ] && { echo "Invalid choice"; return; }
    TARGETS=("$T")
  fi

  for NAME in "${TARGETS[@]}"; do
    systemctl disable --now "wg-quick@$NAME.service" 2>/dev/null || true
    rm -f "/etc/wireguard/$NAME.conf"
    echo "Removed: $NAME"
  done
  systemctl daemon-reload
}

usage() {
  echo
  echo "─────────────────────────────────────────────────────────────"
  echo "How to use it from now on:"
  echo "  sudo wg-wizard              this menu (add / remove / reconnect / status)"
  echo "  sudo wg-reconnect           force-reconnect every tunnel from its saved config"
  echo "  sudo wg-reconnect <name>    force-reconnect just that tunnel"
  echo "  sudo wg show                live handshakes and transfer"
  echo "  sudo wg-quick down <name>   take one tunnel down"
  echo "  sudo wg-quick up <name>     bring it back up"
  echo
  echo "  Tunnels are stored in /etc/wireguard/<name>.conf and come up at boot"
  echo "  via wg-quick@<name>. 'Reconnect' re-reads that file and re-resolves the"
  echo "  endpoint DNS — use it after the server moves or the link goes quiet."
  echo "─────────────────────────────────────────────────────────────"
}

echo "WireGuard Wizard"
echo "  1) Add / configure a tunnel"
echo "  2) Remove a tunnel"
echo "  3) Reconnect a tunnel (force, from the saved config)"
echo "  4) Show status"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) add_conn ;;
  2) remove_conn ;;
  3) reconnect_conn ;;
  4) wg show; echo; systemctl list-units 'wg-quick@*' --no-pager ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
usage
SCRIPT
chmod +x /usr/local/sbin/wg-wizard

# Standalone force-reconnect, so it can be run straight from a script or over SSH
# without stepping through the menu.
cat > /usr/local/sbin/wg-reconnect <<'RECON'
#!/bin/bash
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
if [ -n "$1" ]; then
  TARGETS=("$1")
else
  mapfile -t TARGETS < <(ls /etc/wireguard/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
fi
[ "${#TARGETS[@]}" -eq 0 ] && { echo "No WireGuard tunnels configured."; exit 1; }
for NAME in "${TARGETS[@]}"; do
  [ -f "/etc/wireguard/$NAME.conf" ] || { echo "No such tunnel: $NAME"; continue; }
  echo "Reconnecting $NAME..."
  wg-quick down "$NAME" 2>/dev/null || true
  sleep 1
  wg-quick up "$NAME" || { echo "  failed — check /etc/wireguard/$NAME.conf"; continue; }
  sleep 2
  HS="$(wg show "$NAME" latest-handshakes 2>/dev/null | awk '{print $2; exit}')"
  if [ -n "$HS" ] && [ "$HS" -gt 0 ]; then
    echo "  $NAME up — handshake $(( $(date +%s) - HS ))s ago."
  else
    echo "  $NAME up, but no handshake yet. Endpoint reachable? UDP port open? Keys right?"
  fi
done
RECON
chmod +x /usr/local/sbin/wg-reconnect

echo "Installed. Run:  sudo wg-wizard   (or: sudo wg-reconnect [name])"
EOF

sudo wg-wizard
