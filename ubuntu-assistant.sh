#!/usr/bin/env bash
#
# Ubuntu Assistant — the front door to Ubuntu Essentials.
# Lists every snippet in the repo and runs the one you pick, exactly as if you had
# pasted that snippet's own one-liner into the terminal.
#
#   bash <(curl -fsSL https://sico.securytik.com/ubuntu)
#
set -uo pipefail

RAW="https://raw.githubusercontent.com/mhdhaidarah/Ubuntu-Essentials/main"

B=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[1;36m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; R=$'\033[0m'

# group|file|title|description   — mirrors the SICO Ubuntu catalog
ITEMS=(
  "System & maintenance|update-upgrade.sh|Update & upgrade|Update, full-upgrade, autoremove, then release-upgrade."
  "System & maintenance|hostname.sh|Set hostname|Set the hostname and keep /etc/hosts in sync."
  "System & maintenance|time-date.sh|Timezone & NTP|Pick a timezone and enable NTP time sync."
  "System & maintenance|disk-show.sh|Show disk usage|List mounted filesystems and free space."
  "System & maintenance|disk-extend-100.sh|Extend root disk to 100%|Grow the root LVM volume to fill the disk."
  "System & maintenance|python-install.sh|Install Python toolchain|Python 3 + pip/venv + build tools."
  "Networking|network-ip.sh|Netplan IP wizard|Set IPv4/IPv6 (DHCP/static/SLAAC) + DNS, with safe-apply."
  "Networking|speedtest.sh|Internet speed test|Run a speed test, optionally bound to one uplink."
  "VPN & uplinks|l2tp-client-once.sh|L2TP client (temporary)|One-shot support tunnel. Lives in /tmp, gone on reboot."
  "VPN & uplinks|l2tp-client.sh|L2TP client (permanent)|Reboot-persistent L2TP/IPsec client, multi-VPN."
  "VPN & uplinks|l2tp-server.sh|L2TP server|Run an LNS: add users, see who is online, NAT them online."
  "VPN & uplinks|wireguard-client.sh|WireGuard client|Add/remove WireGuard tunnels, enable on boot."
  "VPN & uplinks|wireguard-server.sh|WireGuard server|Serve peers: add/remove, QR configs, NAT them online."
  "VPN & uplinks|pppoe-client.sh|PPPoE client|Add/remove a persistent PPPoE dialer."
  "Login & access|user-manage.sh|Users & sudo|Add/delete users, grant or revoke sudo, see who is online."
  "Login & access|ssh-key-create.sh|Create an SSH key|Generate an ed25519 keypair and print how to install it."
  "Login & access|ssh-key-add.sh|Add an SSH key|Paste a public key into a user's authorized_keys."
  "Login & access|ssh-key-list.sh|Show / remove SSH keys|List authorized keys by fingerprint and remove any of them."
  "File sharing|smb-client.sh|Mount SMB share|Mount a CIFS share with credentials + automount."
  "File sharing|sshfs-client.sh|Mount SSHFS path|Mount a remote path over SSHFS (key-based)."
  "File sharing|share-server.sh|SMB + SSHFS file server|Turn this box into a file server with per-share users."
  "Apps & services|docker-compose.sh|Docker + Compose|Install Docker Engine + the Compose plugin."
  "Apps & services|cloudflared-install.sh|Cloudflare Tunnel|Install cloudflared from Cloudflare's apt repo."
  "Apps & services|webmin-install.sh|Webmin panel|Install the Webmin web admin panel."
)

command -v curl >/dev/null || { echo "${RED}curl is required.${R}"; exit 1; }

echo
echo "${CYAN}  Ubuntu Assistant${R} ${DIM}— Ubuntu Essentials, one pick away${R}"
echo "${DIM}  sico.securytik.com · github.com/mhdhaidarah/Ubuntu-Essentials${R}"
echo

LAST_GROUP=""
for i in "${!ITEMS[@]}"; do
  IFS='|' read -r group file title desc <<< "${ITEMS[$i]}"
  if [ "$group" != "$LAST_GROUP" ]; then
    echo "  ${B}$group${R}"
    LAST_GROUP="$group"
  fi
  printf "    ${GREEN}%2d${R}) %-26s ${DIM}%s${R}\n" "$((i+1))" "$title" "$desc"
done

echo

read -rp "  Pick a number (q to quit): " CHOICE

# No `exit` and no `return` anywhere below. Quitting used to log people out:
# a bare `exit` closes the caller's SHELL whenever the assistant is sourced or
# exec'd into, and wrapping it in a helper does not help either — `return`
# inside a function returns from the FUNCTION, so execution simply fell through
# and ran whatever item happened to be at that index. Instead the choice only
# sets RUN, and the script ends by reaching its last line, which is safe however
# it was invoked.
#
# A case, not `[ ] || [ ] && { }`: that chain groups as ((A||B)||C)&&D, so one
# reordering silently makes the quit branch fire on a valid choice.
RUN=""
case "${CHOICE:-}" in
  q|Q|"")   echo "  Nothing to do." ;;
  *[!0-9]*) echo "${RED}  Not a number.${R}" ;;
  *)
    IDX=$((CHOICE-1))
    if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "${#ITEMS[@]}" ]; then
      echo "${RED}  No such item.${R}"
    else
      RUN=1
    fi
    ;;
esac

if [ -n "$RUN" ]; then
  IFS='|' read -r group file title desc <<< "${ITEMS[$IDX]}"
  echo
  echo "  ${B}$title${R}"
  echo "  ${DIM}running $RAW/$file${R}"
  echo

  # Hand the terminal to the chosen snippet — identical to pasting its own
  # one-liner. Process substitution (not a pipe) keeps stdin on the keyboard so
  # the snippet's own prompts still work; each snippet calls sudo itself where
  # it needs root.
  #
  # NOT `exec`: that replaced the assistant's process, so control never came
  # back here, and any snippet ending in `exec bash` (hostname.sh does, to pick
  # up the new name) replaced it again — between them they consumed the shell
  # the user started from. As a child it just returns here.
  bash <(curl -fsSL "$RAW/$file")
fi
