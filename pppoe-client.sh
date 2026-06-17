#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/pppoe-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

add_conn() {
  echo "Available interfaces:"
  mapfile -t IFS_LIST < <(ip -o link show | awk -F': ' '$2!="lo"{print $2}')
  for i in "${!IFS_LIST[@]}"; do echo "  $((i+1))) ${IFS_LIST[$i]}"; done
  read -rp "Choose interface number: " N
  IFACE="${IFS_LIST[$((N-1))]}"
  [ -z "$IFACE" ] && { echo "Invalid choice"; exit 1; }

  read -rp "Connection name [wan1]: " NAME; NAME="${NAME:-wan1}"
  read -rp "Username: " USER
  read -rsp "Password: " PASS; echo
  read -rp "Service name (optional, Enter to skip): " SERVICE

  cat > "/etc/pppoe/$NAME.conf" <<CONF
IFACE=$IFACE
USER=$USER
PASS=$PASS
SERVICE=$SERVICE
CONF
  chmod 600 "/etc/pppoe/$NAME.conf"
  systemctl enable --now "pppoe@$NAME.service"
  echo
  echo "Done. Interface=$IFACE name=$NAME"
  echo "Check: systemctl status pppoe@$NAME | ip addr show ppp0"
}

list_conns() {
  mapfile -t CONNS < <(ls /etc/pppoe/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
}

remove_conn() {
  list_conns
  [ "${#CONNS[@]}" -eq 0 ] && { echo "No PPPoE connections found."; return; }
  echo "Existing connections:"
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
    # remove this user's secrets line
    USER=$(grep -E '^USER=' "/etc/pppoe/$NAME.conf" 2>/dev/null | cut -d= -f2-)
    systemctl disable --now "pppoe@$NAME.service" 2>/dev/null || true
    poff "$NAME" 2>/dev/null || true
    rm -f "/etc/ppp/peers/$NAME" "/etc/pppoe/$NAME.conf"
    if [ -n "$USER" ]; then
      sed -i "\#\"$USER\"#d" /etc/ppp/pap-secrets /etc/ppp/chap-secrets 2>/dev/null || true
    fi
    echo "Removed: $NAME"
  done
  systemctl daemon-reload
}

echo "PPPoE Wizard"
echo "  1) Add / configure a connection"
echo "  2) Remove a connection"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) add_conn ;;
  2) remove_conn ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
SCRIPT
chmod +x /usr/local/sbin/pppoe-wizard
echo "Updated. Run:  sudo pppoe-wizard"
EOF

sudo pppoe-wizard
