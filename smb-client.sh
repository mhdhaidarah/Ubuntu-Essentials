#!/usr/bin/env bash
sudo bash <<'EOF'
command -v mount.cifs >/dev/null || { apt-get update && apt-get install -y cifs-utils; }
mkdir -p /etc/smb-mounts
chmod 700 /etc/smb-mounts

systemd_escape_path() { systemd-escape -p --suffix=mount "$1"; }

cat > /usr/local/sbin/smb-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

add_conn() {
  read -rp "Server IP or domain: " SERVER
  read -rp "Share name (remote folder, e.g. data): " SHARE
  read -rp "Username: " USER
  read -rsp "Password: " PASS; echo
  read -rp "Domain/workgroup (optional, Enter to skip): " DOM

  DEFAULT_MP="/opt/$SHARE"
  read -rp "Mount point [$DEFAULT_MP]: " MP; MP="${MP:-$DEFAULT_MP}"

  NAME=$(echo "${SERVER}_${SHARE}" | tr '/. ' '___')
  CRED="/etc/smb-mounts/$NAME.cred"

  {
    echo "username=$USER"
    echo "password=$PASS"
    [ -n "$DOM" ] && echo "domain=$DOM"
  } > "$CRED"
  chmod 600 "$CRED"

  mkdir -p "$MP"

  UNIT="$(systemd-escape -p --suffix=mount "$MP")"
  AUTO="$(systemd-escape -p --suffix=automount "$MP")"

  cat > "/etc/systemd/system/$UNIT" <<UNITF
[Unit]
Description=SMB mount $SERVER/$SHARE -> $MP
After=network-online.target
Wants=network-online.target

[Mount]
What=//$SERVER/$SHARE
Where=$MP
Type=cifs
Options=credentials=$CRED,iocharset=utf8,uid=0,gid=0,file_mode=0660,dir_mode=0770,_netdev,nofail,x-systemd.automount

[Install]
WantedBy=multi-user.target
UNITF

  # record mapping for clean removal later
  echo "MP=$MP" > "/etc/smb-mounts/$NAME.conf"
  echo "UNIT=$UNIT" >> "/etc/smb-mounts/$NAME.conf"
  echo "SERVER=$SERVER" >> "/etc/smb-mounts/$NAME.conf"
  echo "SHARE=$SHARE" >> "/etc/smb-mounts/$NAME.conf"

  systemctl daemon-reload
  systemctl enable --now "$UNIT"
  echo
  echo "Done. //$SERVER/$SHARE mounted at $MP"
  echo "Check: df -h | grep '$MP'  ||  systemctl status '$UNIT'"
}

list_conns() {
  mapfile -t CONNS < <(ls /etc/smb-mounts/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
}

remove_conn() {
  list_conns
  [ "${#CONNS[@]}" -eq 0 ] && { echo "No SMB mounts found."; return; }
  echo "Existing mounts:"
  for i in "${!CONNS[@]}"; do
    . "/etc/smb-mounts/${CONNS[$i]}.conf"
    echo "  $((i+1))) ${CONNS[$i]}  ( //$SERVER/$SHARE -> $MP )"
  done
  echo "  a) remove ALL"
  read -rp "Choose number (or 'a'): " C

  if [ "$C" = "a" ]; then TARGETS=("${CONNS[@]}")
  else
    T="${CONNS[$((C-1))]}"; [ -z "$T" ] && { echo "Invalid choice"; return; }
    TARGETS=("$T")
  fi

  for NAME in "${TARGETS[@]}"; do
    . "/etc/smb-mounts/$NAME.conf"
    AUTO="${UNIT%.mount}.automount"
    systemctl disable --now "$AUTO" 2>/dev/null || true
    systemctl disable --now "$UNIT" 2>/dev/null || true
    umount "$MP" 2>/dev/null || true
    rm -f "/etc/systemd/system/$UNIT"
    rm -f "/etc/smb-mounts/$NAME.cred" "/etc/smb-mounts/$NAME.conf"
    rmdir "$MP" 2>/dev/null || true
    echo "Removed: $NAME ($MP)"
  done
  systemctl daemon-reload
}

echo "SMB Mount Wizard"
echo "  1) Add / mount a share"
echo "  2) Remove a mount"
echo "  3) Show status"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) add_conn ;;
  2) remove_conn ;;
  3) df -h --type=cifs 2>/dev/null; echo; systemctl list-units '*.mount' --no-pager | grep -i opt || true ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
SCRIPT
chmod +x /usr/local/sbin/smb-wizard
echo "Installed. Run:  sudo smb-wizard"
EOF

sudo smb-wizard
