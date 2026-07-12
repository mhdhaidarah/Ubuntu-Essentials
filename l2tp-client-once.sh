#!/usr/bin/env bash
sudo bash <<'EOF'
export DEBIAN_FRONTEND=noninteractive
command -v xl2tpd >/dev/null || { apt-get update && apt-get install -y xl2tpd ppp; }
dpkg -s openssh-server >/dev/null 2>&1 || apt-get install -y openssh-server

# The xl2tpd package ships a system daemon that apt auto-starts. It binds UDP/1701 and owns
# /var/run/xl2tpd/l2tp-control, so a second xl2tpd sharing that FIFO makes dialing a coin flip.
# This wizard runs its own xl2tpd on a private FIFO, so the packaged daemon must be out of the way.
systemctl disable --now xl2tpd >/dev/null 2>&1 || true

# SSH must be up — the whole point of the tunnel is to reach this box.
systemctl enable --now ssh >/dev/null 2>&1 || systemctl enable --now sshd >/dev/null 2>&1 || true

cat > /usr/local/sbin/l2tp-once <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

echo "Temporary L2TP tunnel (runtime lives in /tmp — gone on reboot)"
echo

# This wizard runs its own xl2tpd and must take UDP/1701 + the control FIFO off the packaged
# daemon. If l2tp-client.sh set up PERMANENT VPNs, that daemon is what keeps them online —
# stopping it drops them. Say so instead of silently cutting someone's tunnel.
PERM_COUNT=$(ls /etc/l2tp-vpn/*.conf 2>/dev/null | wc -l)
if [ "$PERM_COUNT" -gt 0 ]; then
  echo "  NOTE: $PERM_COUNT permanent L2TP VPN(s) are configured on this box."
  echo "        They run on the packaged xl2tpd daemon, which this temporary tunnel"
  echo "        has to stop. They will drop now and come back when you run"
  echo "        'sudo l2tp-once-down' (it restarts and re-dials them)."
  read -rp "  Continue? [y/N]: " GO
  [ "$GO" != "y" ] && [ "$GO" != "Y" ] && { echo "  Aborted."; exit 0; }
  echo
fi

while :; do read -rp "Server IP or domain: " SERVER; [ -n "$SERVER" ] && break; echo "  Required."; done
while :; do read -rp "Username: " VPNUSER;      [ -n "$VPNUSER" ] && break; echo "  Required."; done
while :; do read -rsp "Password: " PASS; echo;  [ -n "$PASS" ] && break;    echo "  Required."; done
read -rp "IPsec preshared key (Enter for plain L2TP, no IPsec): " PSK

NAME="once"
RUNDIR="$(mktemp -d /tmp/l2tp-once.XXXXXX)"   # nothing persistent: no /etc, no systemd unit
CTRL="$RUNDIR/l2tp-control"                   # private FIFO — never the system daemon's
USE_IPSEC=0; [ -n "$PSK" ] && USE_IPSEC=1

# A running packaged xl2tpd would hold UDP/1701 and silently swallow our packets.
systemctl stop xl2tpd 2>/dev/null || true

# Reap ORPHANED temporary tunnels from an earlier run of this wizard (a crash, a closed
# SSH session, an old version). They are not under systemd, so stopping the packaged unit
# does not touch them — they just sit there holding UDP/1701. Several xl2tpds bound to the
# same port is exactly what makes dialing a coin flip: the L2TP replies land in whichever
# socket the kernel picks. Only ever kill instances whose config lives in /tmp, which by
# definition means a disposable wizard run — never a permanent VPN.
for _pid in $(pgrep -f 'xl2tpd .*-c /tmp/l2tp-(once|wizard-once)\.' 2>/dev/null); do
  echo "  reaping stale temporary xl2tpd (pid $_pid) from an earlier run..."
  kill "$_pid" 2>/dev/null || true
done
sleep 1

# --- optional IPsec ---
if [ "$USE_IPSEC" = "1" ]; then
  command -v ipsec >/dev/null || { echo "Installing strongswan..."; apt-get update && apt-get install -y strongswan >/dev/null; }
  touch /etc/ipsec.secrets; chmod 600 /etc/ipsec.secrets
  echo ": PSK \"$PSK\"  # l2tp-once" >> /etc/ipsec.secrets
  mkdir -p /etc/ipsec.d
  cat > "/etc/ipsec.d/l2tp-once.conf" <<IPSEC
conn l2tp-once
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
  grep -q "^include /etc/ipsec.d/\*.conf" /etc/ipsec.conf 2>/dev/null || echo "include /etc/ipsec.d/*.conf" >> /etc/ipsec.conf
  ipsec restart 2>/dev/null || systemctl restart strongswan 2>/dev/null || systemctl restart strongswan-starter 2>/dev/null || true
  sleep 3
  ipsec up l2tp-once || echo "IPsec failed to establish."
fi

# --- xl2tpd, entirely under $RUNDIR ---
# 'max redials' must be >= 1: xl2tpd rejects 0 with "rmax value must be at least 1" and
# then refuses to load the WHOLE config, so the daemon never starts. There is no
# "unlimited" — a large count is how you say "keep trying".
# Keep this heredoc free of '#' comments: xl2tpd's parser treats them as data and dies
# with "line too long or no '=' in data".
cat > "$RUNDIR/xl2tpd.conf" <<CONF
[global]
port = 1701

[lac $NAME]
lns = $SERVER
ppp debug = no
pppoptfile = $RUNDIR/options.l2tpd
length bit = yes
redial = yes
redial timeout = 10
max redials = 65535
CONF

# --- Keepalives: read this before blaming the client ---
# If your LNS is a MikroTik, its L2TP server keepalive-timeout (default 30s) counts ONLY
# L2TP control-channel HELLOs. xl2tpd sends its first HELLO after 60s of control-channel
# idle, so it can never beat a 30s timeout: the router tears the tunnel down with
# CDN + StopCCN ~25s after it comes up, even while data is flowing. PPP LCP echoes do not
# save you — the router answers them and kills the session anyway. Fix it on the router:
#     /interface l2tp-server server set keepalive-timeout=disabled     (or a value > 60)
# The lcp-echo-* + persist/redial below only make this client notice a dead peer and redial;
# they cannot prevent an LNS-side keepalive timeout.
cat > "$RUNDIR/options.l2tpd" <<OPT
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
mtu 1400
mru 1400
noipdefault
nodefaultroute
persist
maxfail 0
holdoff 5
lcp-echo-interval 10
lcp-echo-failure 6
connect-delay 5000
name "$VPNUSER"
password "$PASS"
OPT
chmod 600 "$RUNDIR/options.l2tpd"

# Teardown command is written BEFORE dialing: with persist/redial the tunnel may come up
# after this wizard has given up waiting, and it must always be killable.
cat > /usr/local/sbin/l2tp-once-down <<DOWN
#!/bin/bash
[ "\$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
echo "d $NAME" > "$CTRL" 2>/dev/null || true
sleep 1
[ -f "$RUNDIR/xl2tpd.pid" ] && kill "\$(cat "$RUNDIR/xl2tpd.pid")" 2>/dev/null || true
pkill -f "$RUNDIR" 2>/dev/null || true
rm -rf "$RUNDIR"
if [ "$USE_IPSEC" = "1" ]; then
  ipsec down l2tp-once 2>/dev/null || true
  rm -f /etc/ipsec.d/l2tp-once.conf
  sed -i "/# l2tp-once/d" /etc/ipsec.secrets 2>/dev/null || true
  ipsec restart 2>/dev/null || systemctl restart strongswan 2>/dev/null || true
fi
rm -f /usr/local/sbin/l2tp-once-down /usr/local/sbin/l2tp-once-reconnect
echo "Tunnel down, temporary files removed."

# Hand UDP/1701 back to the packaged daemon and re-dial any permanent VPNs we displaced.
if ls /etc/l2tp-vpn/*.conf >/dev/null 2>&1; then
  echo "Restoring the permanent L2TP VPN(s)..."
  systemctl enable --now xl2tpd >/dev/null 2>&1 || true
  sleep 2
  for _f in /etc/l2tp-vpn/*.conf; do
    _n="\$(basename "\$_f" .conf)"
    echo "c \$_n" > /var/run/xl2tpd/l2tp-control 2>/dev/null || true
    echo "  re-dialled \$_n"
  done
fi
DOWN
chmod +x /usr/local/sbin/l2tp-once-down

# Force-reconnect using the SAME temporary config. xl2tpd redials on its own, but after a
# long outage (or if the daemon itself died) this re-dials now — without re-typing the
# credentials, which is the whole point during a support call.
cat > /usr/local/sbin/l2tp-once-reconnect <<RECON
#!/bin/bash
[ "\$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
[ -d "$RUNDIR" ] || { echo "The temporary tunnel is gone (rebooted or torn down). Re-run: sudo l2tp-once"; exit 1; }

# Revive our private xl2tpd if it is no longer running — the config is still on disk.
if ! pgrep -f "$RUNDIR/xl2tpd.conf" >/dev/null 2>&1; then
  echo "xl2tpd is not running — restarting it from the saved config..."
  systemctl stop xl2tpd 2>/dev/null || true
  setsid xl2tpd -D -c "$RUNDIR/xl2tpd.conf" -C "$CTRL" -p "$RUNDIR/xl2tpd.pid" \\
    >> "$RUNDIR/xl2tpd.log" 2>&1 < /dev/null &
  for _ in \$(seq 1 20); do [ -p "$CTRL" ] && break; sleep 0.5; done
fi

echo "Redialing $NAME -> $SERVER ..."
echo "d $NAME" > "$CTRL" 2>/dev/null || true
sleep 2
echo "c $NAME" > "$CTRL" 2>/dev/null || true

for _ in \$(seq 1 20); do
  PPPIF=\$(ip -o -4 addr show 2>/dev/null | grep -oE 'ppp[0-9]+' | head -1)
  if [ -n "\$PPPIF" ]; then
    echo "Connected: \$PPPIF \$(ip -4 -o addr show "\$PPPIF" | awk '{print \$4}')"
    exit 0
  fi
  sleep 1
done
echo "Still not up. Check the server, then: tail -20 $RUNDIR/xl2tpd.log"
exit 1
RECON
chmod +x /usr/local/sbin/l2tp-once-reconnect

echo
echo "Starting L2TP to $SERVER as $VPNUSER  (IPsec: $([ "$USE_IPSEC" = 1 ] && echo on || echo off)) ..."
# setsid: the tunnel must outlive this wizard and the SSH session that launched it.
setsid xl2tpd -D -c "$RUNDIR/xl2tpd.conf" -C "$CTRL" -p "$RUNDIR/xl2tpd.pid" \
  > "$RUNDIR/xl2tpd.log" 2>&1 < /dev/null &
disown 2>/dev/null || true

# xl2tpd creates the control FIFO a moment after start — dialing before it exists is a no-op.
for _ in $(seq 1 20); do [ -p "$CTRL" ] && break; sleep 0.5; done
[ -p "$CTRL" ] || { echo "xl2tpd failed to start:"; tail -5 "$RUNDIR/xl2tpd.log"; /usr/local/sbin/l2tp-once-down >/dev/null 2>&1; exit 1; }

echo "c $NAME" > "$CTRL"
echo "Dialing..."

for _ in $(seq 1 30); do
  PPPIF=$(ip -o -4 addr show 2>/dev/null | grep -oE 'ppp[0-9]+' | head -1)
  if [ -n "$PPPIF" ]; then
    TUNIP=$(ip -4 -o addr show "$PPPIF" | awk '{print $4}'); TUNIP="${TUNIP%%/*}"
    echo
    echo "Connected: $PPPIF  $TUNIP"
    echo
    echo "─────────────────────────────────────────────────────────────"
    echo "How to use it:"
    echo "  ssh <user>@$TUNIP          reach this box from the far side of the VPN"
    echo "  sudo l2tp-once-reconnect      force a redial (same credentials, no re-typing)"
    echo "  sudo l2tp-once-down           tear it down and clean up"
    echo
    echo "  This tunnel is TEMPORARY: it lives in $RUNDIR, has no systemd unit and"
    echo "  no /etc config, so a reboot clears it. It redials by itself if it drops."
    echo "─────────────────────────────────────────────────────────────"
    exit 0
  fi
  sleep 1
done

echo
echo "No ppp interface after 30s. Server reachable? Credentials right? UDP 1701 open?"
[ "$USE_IPSEC" = 1 ] && echo "IPsec is on — check 'ipsec status' and that the PSK matches." \
                     || echo "Plain L2TP — if the server requires IPsec, re-run and give a PSK."
echo "If it authenticated and then dropped after ~25s, see the keepalive note in this script."
echo "--- xl2tpd log ---"; tail -15 "$RUNDIR/xl2tpd.log" 2>/dev/null
echo "xl2tpd is still retrying in the background. Stop it with: sudo l2tp-once-down"
exit 1
SCRIPT
chmod +x /usr/local/sbin/l2tp-once
echo "Installed. Run:  sudo l2tp-once"
EOF

sudo l2tp-once
