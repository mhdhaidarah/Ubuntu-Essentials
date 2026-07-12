#!/usr/bin/env bash
sudo bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive
command -v xl2tpd >/dev/null || { apt-get update && apt-get install -y strongswan xl2tpd ppp; }
mkdir -p /etc/l2tp-vpn
chmod 700 /etc/l2tp-vpn
mkdir -p /etc/xl2tpd /etc/ppp

cat > /usr/local/sbin/l2tp-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

list_conns() {
  mapfile -t CONNS < <(ls /etc/l2tp-vpn/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
}

# xl2tpd.conf holds ONE [lac] block per VPN, so it must always be rebuilt from the full set
# of saved connections in /etc/l2tp-vpn — writing it from a single connection would silently
# drop every other VPN on the box.
#
# Two xl2tpd config-parser landmines, both of which stop the daemon loading AT ALL:
#   * 'max redials' must be >= 1 (0 is not "unlimited" — it is a fatal error).
#   * no '#' comments inside the generated file; it reads them as data.
rebuild_xl2tpd() {
  : > /etc/xl2tpd/xl2tpd.conf
  local f
  for f in /etc/l2tp-vpn/*.conf; do
    [ -e "$f" ] || continue
    # subshell: sourcing sets NAME/SERVER/USER and must not clobber the caller's copies
    (
      . "$f"
      cat >> /etc/xl2tpd/xl2tpd.conf <<RE
[lac $NAME]
lns = $SERVER
ppp debug = no
pppoptfile = /etc/ppp/options.l2tpd.$NAME
length bit = yes
redial = yes
redial timeout = 10
max redials = 65535
RE
    )
  done
}

add_conn() {
  read -rp "Connection name [vpn1]: " NAME; NAME="${NAME:-vpn1}"
  read -rp "Server IP or domain: " SERVER
  read -rp "Username: " USER
  read -rsp "Password: " PASS; echo

  # IPsec is opt-in: most MikroTik/L2TP setups run plain L2TP, and silently attempting
  # IPsec against a server that doesn't want it is the usual reason a dial never comes up.
  read -rp "Use IPsec? (y = enter a PSK, Enter = plain L2TP, no IPsec) [n]: " USE_IPSEC
  PSK=""
  if [ "$USE_IPSEC" = "y" ] || [ "$USE_IPSEC" = "Y" ]; then
    while :; do
      read -rsp "IPsec preshared key: " PSK; echo
      [ -n "$PSK" ] && break
      echo "  A PSK is required when IPsec is on (Ctrl-C to abort)."
    done
  fi
  read -rp "Route all traffic through VPN? [y/N]: " DEFRT

  # 1400 is the value verified against a plain-L2TP LNS; IPsec's ESP overhead needs a
  # smaller ceiling or large packets fragment and stall.
  if [ -n "$PSK" ]; then MTU=1280; else MTU=1400; fi

  # --- strongSwan (IPsec) ---
  if [ -n "$PSK" ]; then
    # ipsec secrets
    touch /etc/ipsec.secrets; chmod 600 /etc/ipsec.secrets
    sed -i "/# l2tp-$NAME/d" /etc/ipsec.secrets 2>/dev/null || true
    echo ": PSK \"$PSK\"  # l2tp-$NAME" >> /etc/ipsec.secrets

    # ipsec.conf connection block
    grep -q "^include /etc/ipsec.d/\*.conf" /etc/ipsec.conf 2>/dev/null || {
      grep -q "config setup" /etc/ipsec.conf 2>/dev/null || echo "config setup" >> /etc/ipsec.conf
      echo "include /etc/ipsec.d/*.conf" >> /etc/ipsec.conf
    }
    mkdir -p /etc/ipsec.d
    cat > "/etc/ipsec.d/l2tp-$NAME.conf" <<IPSEC
conn l2tp-$NAME
    keyexchange=ikev1
    authby=secret
    auto=add
    type=transport
    left=%defaultroute
    leftprotoport=17/1701
    right=$SERVER
    rightprotoport=17/1701
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha1,aes128-sha1,3des-sha1!
IPSEC
    systemctl enable strongswan-starter >/dev/null 2>&1 || systemctl enable strongswan >/dev/null 2>&1 || true
    systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || ipsec restart
  fi

  # --- save this connection, then rebuild xl2tpd.conf from ALL of them ---
  {
    echo "NAME=$NAME"; echo "SERVER=$SERVER"; echo "USER=$USER"
    echo "PSK=$( [ -n "$PSK" ] && echo yes || echo no )"
  } > "/etc/l2tp-vpn/$NAME.conf"
  rebuild_xl2tpd

  # --- Keepalives: read this before blaming the client ---
  # If the LNS is a MikroTik, its L2TP server keepalive-timeout (default 30s) counts ONLY
  # L2TP control-channel HELLOs. xl2tpd sends its first HELLO after 60s of control-channel
  # idle, so it can never beat a 30s timeout: the router tears the tunnel down with
  # CDN + StopCCN ~25s after it comes up, even while data is flowing. PPP LCP echoes do not
  # save you — the router answers them and kills the session anyway. Fix it on the router:
  #     /interface l2tp-server server set keepalive-timeout=disabled     (or a value > 60)
  # persist/maxfail/holdoff + lcp-echo-* below let this client notice a dead peer and redial
  # (the packaged systemd unit only dials once); they cannot prevent an LNS-side timeout.
  cat > "/etc/ppp/options.l2tpd.$NAME" <<PPPOPT
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
mtu $MTU
mru $MTU
noipdefault
$( [ "$DEFRT" = "y" ] || [ "$DEFRT" = "Y" ] && echo "defaultroute" && echo "replacedefaultroute" )
usepeerdns
persist
maxfail 0
holdoff 5
lcp-echo-interval 10
lcp-echo-failure 6
connect-delay 5000
name "$USER"
password "$PASS"
PPPOPT
  chmod 600 "/etc/ppp/options.l2tpd.$NAME"

  # control + connect helper scripts
  cat > "/usr/local/sbin/l2tp-up-$NAME" <<UP
#!/bin/bash
$( [ -n "$PSK" ] && echo "ipsec up l2tp-$NAME" )
echo "c $NAME" > /var/run/xl2tpd/l2tp-control
UP
  cat > "/usr/local/sbin/l2tp-down-$NAME" <<DOWN
#!/bin/bash
echo "d $NAME" > /var/run/xl2tpd/l2tp-control
$( [ -n "$PSK" ] && echo "ipsec down l2tp-$NAME 2>/dev/null || true" )
DOWN
  chmod +x "/usr/local/sbin/l2tp-up-$NAME" "/usr/local/sbin/l2tp-down-$NAME"

  # The permanent client rides the packaged xl2tpd daemon. l2tp-client-once.sh disables that
  # daemon (it runs its own private instance), so re-enable it here — otherwise a box that
  # once hosted a temporary support tunnel could never bring a permanent VPN up again.
  systemctl enable xl2tpd >/dev/null 2>&1 || true
  systemctl restart xl2tpd
  sleep 2

  # The restart above dropped every tunnel xl2tpd was holding — re-dial the other VPNs,
  # otherwise adding a second VPN quietly takes the first one offline until the next reboot.
  for _f in /etc/l2tp-vpn/*.conf; do
    [ -e "$_f" ] || continue
    _n="$(basename "$_f" .conf)"
    [ "$_n" = "$NAME" ] && continue
    echo "c $_n" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
  done

  # systemd service for reboot persistence
  cat > "/etc/systemd/system/l2tp-$NAME.service" <<UNIT
[Unit]
Description=L2TP VPN ($NAME)
After=network-online.target xl2tpd.service $( [ -n "$PSK" ] && echo "strongswan-starter.service" )
Wants=network-online.target
Requires=xl2tpd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/sbin/l2tp-up-$NAME
ExecStop=/usr/local/sbin/l2tp-down-$NAME

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now "l2tp-$NAME.service"
  sleep 3
  echo
  echo "Done. VPN=$NAME -> $SERVER  (IPsec: $( [ -n "$PSK" ] && echo on || echo off ))"
  echo "Check: ip addr show ppp0 | ip route"
}

remove_conn() {
  list_conns
  [ "${#CONNS[@]}" -eq 0 ] && { echo "No L2TP VPNs found."; return; }
  echo "Existing VPNs:"
  for i in "${!CONNS[@]}"; do
    . "/etc/l2tp-vpn/${CONNS[$i]}.conf"
    echo "  $((i+1))) ${CONNS[$i]}  ( $SERVER user=$USER ipsec=$PSK )"
  done
  echo "  a) remove ALL"
  read -rp "Choose number (or 'a'): " C
  if [ "$C" = "a" ]; then TARGETS=("${CONNS[@]}")
  else T="${CONNS[$((C-1))]}"; [ -z "$T" ] && { echo "Invalid"; return; }; TARGETS=("$T"); fi

  for NAME in "${TARGETS[@]}"; do
    systemctl disable --now "l2tp-$NAME.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/l2tp-$NAME.service"
    rm -f "/usr/local/sbin/l2tp-up-$NAME" "/usr/local/sbin/l2tp-down-$NAME"
    rm -f "/etc/ppp/options.l2tpd.$NAME"
    rm -f "/etc/ipsec.d/l2tp-$NAME.conf"
    sed -i "/# l2tp-$NAME/d" /etc/ipsec.secrets 2>/dev/null || true
    rm -f "/etc/l2tp-vpn/$NAME.conf"
    echo "Removed: $NAME"
  done
  # rebuild a clean xl2tpd.conf from whatever remains
  rebuild_xl2tpd
  systemctl restart xl2tpd 2>/dev/null || true
  systemctl restart strongswan-starter 2>/dev/null || systemctl restart strongswan 2>/dev/null || true
  systemctl daemon-reload
  sleep 2

  # ...and re-dial the survivors, which the restart just dropped.
  list_conns
  for _n in "${CONNS[@]}"; do
    echo "c $_n" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
  done
}

# Force a redial from the stored config: drop the LAC, then dial it again. The tunnel can
# sit "configured" but dead after the peer reboots or the WAN flaps, and pppd's own redial
# only fires when it notices the drop — this makes it happen now.
reconnect_conn() {
  list_conns
  [ "${#CONNS[@]}" -eq 0 ] && { echo "No L2TP VPNs found."; return; }
  echo "Existing VPNs:"
  local i
  for i in "${!CONNS[@]}"; do echo "  $((i+1))) ${CONNS[$i]}"; done
  echo "  a) reconnect ALL"
  read -rp "Choose number (or 'a'): " C
  if [ "$C" = "a" ]; then TARGETS=("${CONNS[@]}")
  else T="${CONNS[$((C-1))]}"; [ -z "$T" ] && { echo "Invalid"; return; }; TARGETS=("$T"); fi

  # xl2tpd must actually be running for the control FIFO to exist.
  systemctl is-active xl2tpd >/dev/null 2>&1 || { echo "Starting xl2tpd..."; systemctl start xl2tpd; sleep 2; }

  for NAME in "${TARGETS[@]}"; do
    ( . "/etc/l2tp-vpn/$NAME.conf"
      echo "Reconnecting $NAME -> $SERVER ..."
      [ "$PSK" = "yes" ] && { ipsec down "l2tp-$NAME" 2>/dev/null || true; ipsec up "l2tp-$NAME" 2>/dev/null || true; }
    )
    echo "d $NAME" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
    sleep 2
    echo "c $NAME" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
  done

  sleep 5
  if ip -o -4 addr show 2>/dev/null | grep -q ppp; then
    echo "Up:"; ip -o -4 addr show | grep ppp | awk '{print "  " $2 "  " $4}'
  else
    echo "No ppp interface yet. Check 'journalctl -u xl2tpd -n 30'."
    echo "If it authenticates then drops after ~25s, raise keepalive-timeout on the server."
  fi
}

usage() {
  echo
  echo "─────────────────────────────────────────────────────────────"
  echo "How to use it from now on:"
  echo "  sudo l2tp-wizard             this menu (add / remove / reconnect / status)"
  echo "  sudo l2tp-reconnect          force-redial every VPN from its saved config"
  echo "  sudo l2tp-reconnect <name>   force-redial just that VPN"
  echo "  sudo l2tp-up-<name>          dial one VPN"
  echo "  sudo l2tp-down-<name>        hang one VPN up"
  echo "  ip addr show ppp0            check the tunnel address"
  echo
  echo "  VPNs are saved in /etc/l2tp-vpn/ and dial at boot via l2tp-<name>.service."
  echo "  They redial by themselves after a drop (persist + lcp-echo); 'reconnect' just"
  echo "  forces it immediately."
  echo "─────────────────────────────────────────────────────────────"
}

echo "L2TP/IPsec VPN Wizard"
echo "  1) Add / configure a VPN"
echo "  2) Remove a VPN"
echo "  3) Reconnect a VPN (force redial from the saved config)"
echo "  4) Show status"
read -rp "Choose: " CHOICE
case "$CHOICE" in
  1) add_conn ;;
  2) remove_conn ;;
  3) reconnect_conn ;;
  4) ip addr show ppp0 2>/dev/null || echo "ppp0 not up"; echo
     ipsec status 2>/dev/null || true; echo
     systemctl list-units 'l2tp-*' --no-pager ;;
  *) echo "Invalid choice"; exit 1 ;;
esac
usage
SCRIPT
chmod +x /usr/local/sbin/l2tp-wizard

# Standalone force-redial, usable over SSH without walking the menu.
cat > /usr/local/sbin/l2tp-reconnect <<'RECON'
#!/bin/bash
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
if [ -n "$1" ]; then
  TARGETS=("$1")
else
  mapfile -t TARGETS < <(ls /etc/l2tp-vpn/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//')
fi
[ "${#TARGETS[@]}" -eq 0 ] && { echo "No L2TP VPNs configured."; exit 1; }
systemctl is-active xl2tpd >/dev/null 2>&1 || { systemctl start xl2tpd; sleep 2; }
for NAME in "${TARGETS[@]}"; do
  [ -f "/etc/l2tp-vpn/$NAME.conf" ] || { echo "No such VPN: $NAME"; continue; }
  ( . "/etc/l2tp-vpn/$NAME.conf"
    echo "Reconnecting $NAME -> $SERVER ..."
    [ "$PSK" = "yes" ] && { ipsec down "l2tp-$NAME" 2>/dev/null || true; ipsec up "l2tp-$NAME" 2>/dev/null || true; } )
  echo "d $NAME" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
  sleep 2
  echo "c $NAME" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
done
sleep 5
ip -o -4 addr show 2>/dev/null | grep ppp | awk '{print "  up: " $2 "  " $4}' || \
  echo "  no ppp interface yet — check 'journalctl -u xl2tpd -n 30'"
RECON
chmod +x /usr/local/sbin/l2tp-reconnect

echo "Installed. Run:  sudo l2tp-wizard   (or: sudo l2tp-reconnect [name])"
EOF

sudo l2tp-wizard
