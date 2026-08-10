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
# One request for the whole repo instead of 35. A machine behind a slow link
# used to spend a minute fetching snippets one at a time.
TARBALL="https://codeload.github.com/mhdhaidarah/Ubuntu-Essentials/tar.gz/refs/heads/main"
CACHE_MAX_AGE_DAYS=7

B=$'\033[1m'; DIM=$'\033[2m'; CYAN=$'\033[1;36m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; R=$'\033[0m'

# group|file|title|description   — mirrors the SICO Ubuntu catalog
ITEMS=(
  "System & maintenance|server-triage.sh|Server health triage|What is wrong with this box: load, memory, disk, failed units, OOM kills, errors."
  "System & maintenance|disk-rescue.sh|Disk space rescue|Find what filled the disk and reclaim it — journal, apt, old kernels, Docker."
  "System & maintenance|swap-setup.sh|Swap / zram|Add a swap file or zram, remove one, tune swappiness."
  "System & maintenance|backup-restore.sh|Backup & restore|Archive /etc /root /home /opt somewhere else, schedule it, restore from it."
  "System & maintenance|update-upgrade.sh|Update & upgrade|Update, full-upgrade, autoremove, turn on automatic security updates, then release-upgrade."
  "System & maintenance|hostname.sh|Set hostname|Set the hostname and keep /etc/hosts in sync."
  "System & maintenance|time-date.sh|Timezone & NTP|Pick a timezone and enable NTP time sync."
  "System & maintenance|disk-show.sh|Show disk usage|List mounted filesystems and free space."
  "System & maintenance|disk-extend-100.sh|Extend root disk to 100%|Grow the root LVM volume to fill the disk."
  "System & maintenance|python-install.sh|Install Python toolchain|Python 3 + pip/venv + build tools."
  "Networking|firewall.sh|Firewall (ufw)|Open/close ports with presets, and it refuses to lock you out of SSH."
  "Networking|net-diag.sh|Network diagnostics|Loss and jitter, mtr, per-resolver DNS timing, MTU discovery, port reachability."
  "Networking|dns-setup.sh|DNS resolver wizard|Which layer actually owns your DNS, set it, test it, put it back."
  "Networking|network-ip.sh|Netplan IP wizard|Set IPv4/IPv6 (DHCP/static/SLAAC) + DNS, with safe-apply."
  "Networking|speedtest.sh|Internet speed test|Run a speed test, optionally bound to one uplink."
  "VPN & uplinks|l2tp-client-once.sh|L2TP client (temporary)|One-shot support tunnel. Lives in /tmp, gone on reboot."
  "VPN & uplinks|l2tp-client.sh|L2TP client (permanent)|Reboot-persistent L2TP/IPsec client, multi-VPN."
  "VPN & uplinks|l2tp-server.sh|L2TP server|Run an LNS: add users, see who is online, NAT them online."
  "VPN & uplinks|wireguard-client.sh|WireGuard client|Add/remove WireGuard tunnels, enable on boot."
  "VPN & uplinks|wireguard-server.sh|WireGuard server|Serve peers: add/remove, QR configs, NAT them online."
  "VPN & uplinks|pppoe-client.sh|PPPoE client|Add/remove a persistent PPPoE dialer."
  "Login & access|ssh-control.sh|SSH server control|Port, root policy, password / key / both-required lockdown, fail2ban, allow-list, idle timeout, host keys, backups."
  "Login & access|user-manage.sh|Users & sudo|Add/delete users, grant or revoke sudo, see who is online."
  "Login & access|ssh-key-create.sh|Create an SSH key|Generate an ed25519 keypair and print how to install it."
  "Login & access|ssh-key-add.sh|Add an SSH key|Paste a public key into a user's authorized_keys."
  "Login & access|ssh-key-list.sh|Show / remove SSH keys|List authorized keys by fingerprint and remove any of them."
  "File sharing|smb-client.sh|Mount SMB share|Mount a CIFS share with credentials + automount."
  "File sharing|sshfs-client.sh|Mount SSHFS path|Mount a remote path over SSHFS (key-based)."
  "File sharing|share-server.sh|SMB + SSHFS file server|Turn this box into a file server with per-share users."
  "SAMM|samm-install.sh|Install SAMM|Pre-flight this box, then run the official installer for the latest release."
  "SAMM|samm-health.sh|SAMM health check|Read-only diagnosis: services, database, FreeRADIUS, panel, error board."
  "Apps & services|docker-compose.sh|Docker + Compose|Install Docker Engine + the Compose plugin."
  "Apps & services|cloudflared-install.sh|Cloudflare Tunnel|Install cloudflared from Cloudflare's apt repo."
  "Apps & services|webmin-install.sh|Webmin panel|Install the Webmin web admin panel."
)

command -v curl >/dev/null || { echo "${RED}curl is required.${R}"; exit 1; }

# --- offline copy ------------------------------------------------------------
# Most snippets here are pure local configuration — SSH, IP, DNS, users, disks,
# health. They have no business needing the internet at run time, so the first
# run copies EVERY snippet onto the box and later runs read from there. What a
# snippet does with the network afterwards is its own affair: apt-get still
# needs a mirror, samm-install.sh still needs the release.
cache_dir() {
  if [ "$(id -u)" -eq 0 ] || [ -w /usr/local/share ]; then
    echo "/usr/local/share/ubuntu-essentials"
  else
    echo "${XDG_DATA_HOME:-$HOME/.local/share}/ubuntu-essentials"
  fi
}
CACHE=$(cache_dir)

cache_count() { ls "$CACHE"/*.sh 2>/dev/null | wc -l; }

cache_age_days() {
  [ -f "$CACHE/.stamp" ] || { echo 9999; return; }
  local then now
  then=$(cat "$CACHE/.stamp" 2>/dev/null) || then=0
  now=$(date +%s)
  echo $(( (now - ${then:-0}) / 86400 ))
}

# Land each file with a rename, never a partial write. A truncated snippet in
# the cache is worse than no cache at all: it runs happily and stops half way
# through reconfiguring your network.
cache_put() {
  local name="$1" src="$2"
  head -c2 "$src" 2>/dev/null | grep -q '#!' || return 1   # not a script; skip
  cp "$src" "$CACHE/.new.$name" 2>/dev/null || return 1
  chmod 644 "$CACHE/.new.$name" 2>/dev/null
  mv -f "$CACHE/.new.$name" "$CACHE/$name" 2>/dev/null
}

# Whole repo in one tarball, with a per-file fetch as the fallback: a network
# that blocks codeload but allows raw.githubusercontent is common enough on
# corporate links, and one blocked host should not cost the offline copy.
refresh_cache() {
  mkdir -p "$CACHE" 2>/dev/null || return 1
  local tmp n=0 f
  tmp=$(mktemp -d) || return 1
  if curl -fsSL --connect-timeout 8 --max-time 120 -o "$tmp/repo.tgz" "$TARBALL" 2>/dev/null \
     && [ -s "$tmp/repo.tgz" ] && tar xzf "$tmp/repo.tgz" -C "$tmp" 2>/dev/null; then
    local src; src=$(find "$tmp" -maxdepth 1 -type d -name 'Ubuntu-Essentials-*' 2>/dev/null | head -1)
    if [ -n "$src" ]; then
      for f in "$src"/*.sh; do [ -f "$f" ] || continue
        cache_put "$(basename "$f")" "$f" && n=$((n+1)); done
    fi
  fi
  if [ "$n" -eq 0 ]; then
    for item in "${ITEMS[@]}" "x|ubuntu-assistant.sh|x|x"; do
      IFS='|' read -r _ f _ _ <<< "$item"
      curl -fsSL --connect-timeout 8 -o "$tmp/$f" "$RAW/$f" 2>/dev/null \
        && cache_put "$f" "$tmp/$f" && n=$((n+1))
    done
  fi
  rm -rf "$tmp"
  [ "$n" -eq 0 ] && return 1
  date +%s > "$CACHE/.stamp" 2>/dev/null
  echo "$n"
}

# --- make it a permanent command --------------------------------------------
# Pasting a curl URL every time is the whole friction this removes: the first
# run drops a tiny launcher on the box, so afterwards the menu is one word.
# The launcher re-fetches the menu on every run rather than caching this file,
# so a machine that was set up once never shows a stale, half-broken catalog.
LAUNCHER_NAME="ubuntu-assistant"
URL="https://sico.securytik.com/ubuntu"

launcher_body() {
  cat <<LAUNCH
#!/usr/bin/env bash
# Ubuntu Assistant — installed launcher. Fetches the current menu each run, so
# this file never goes stale. Remove it with: rm \$0
URL="$URL"
T=\$(mktemp) || exit 1
trap 'rm -f "\$T"' EXIT
# Download FIRST, then run. \`bash <(curl ...)\` hands bash an empty stream when
# the network is down and looks like a menu that silently did nothing.
if ! curl -fsSL --connect-timeout 8 "\$URL" -o "\$T" 2>/dev/null || [ ! -s "\$T" ]; then
  # Offline: run the copy the assistant left on this box. Losing the menu is
  # the one failure that would make the whole offline copy pointless.
  for C in "/usr/local/share/ubuntu-essentials/ubuntu-assistant.sh" \\
           "\${XDG_DATA_HOME:-\$HOME/.local/share}/ubuntu-essentials/ubuntu-assistant.sh"; do
    [ -r "\$C" ] && { UA_VIA_LAUNCHER=1 exec bash "\$C"; }
  done
  echo "Ubuntu Assistant: no network and no offline copy on this machine."
  exit 1
fi
UA_VIA_LAUNCHER=1 bash "\$T"
LAUNCH
}

install_launcher() {
  local dir="/usr/local/bin" tgt
  if [ ! -w "$dir" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
      tgt="$dir/$LAUNCHER_NAME"
      launcher_body | sudo tee "$tgt" >/dev/null 2>&1 && sudo chmod 755 "$tgt" && { echo "$tgt"; return 0; }
    fi
    # No root and no passwordless sudo: a personal copy beats nagging for a
    # password just to save some typing later.
    dir="$HOME/.local/bin"; mkdir -p "$dir" 2>/dev/null || return 1
  fi
  tgt="$dir/$LAUNCHER_NAME"
  launcher_body > "$tgt" 2>/dev/null || return 1
  chmod 755 "$tgt" 2>/dev/null
  echo "$tgt"
}

# Seed the shell's history so the literal "press up, press enter" works in the
# NEXT login too, not only in this one. The running shell keeps history in
# memory and flushes it on exit, so we append to the file and let it merge —
# Ubuntu's stock bashrc sets `histappend`, which is what makes that safe. When
# the assistant is run under sudo, $HOME is root's; the history the user will
# actually arrow through is $SUDO_USER's.
seed_history() {
  local h u="${SUDO_USER:-}"
  if [ -n "$u" ] && [ "$u" != "root" ]; then h=$(getent passwd "$u" | cut -d: -f6)/.bash_history
  else h="$HOME/.bash_history"; fi
  [ -e "$h" ] || return 0
  [ -w "$h" ] || return 0
  grep -qxF "$LAUNCHER_NAME" "$h" 2>/dev/null && return 0
  printf '%s\n' "$LAUNCHER_NAME" >> "$h" 2>/dev/null || true
}

# Installing on EVERY run, launcher or not, is deliberate: it is idempotent, and
# it is the only way a box set up months ago picks up a fixed launcher. Only the
# advertising is suppressed for people already using it.
LAUNCHER_PATH=$(install_launcher) || LAUNCHER_PATH=""
[ -n "$LAUNCHER_PATH" ] && seed_history
[ "${UA_VIA_LAUNCHER:-}" = "1" ] && LAUNCHER_PATH=""

# First run seeds the copy; after that only a stale one is refreshed, and a
# refresh that fails is silent — the whole point is that the box keeps working
# without the network, so a failed update must never block the menu.
CACHE_NOTE=""
if [ "$(cache_count)" -eq 0 ]; then
  echo "  ${DIM}first run — copying every snippet to $CACHE for offline use...${R}"
  CACHED=$(refresh_cache) || CACHED=""
  if [ -n "$CACHED" ]; then CACHE_NOTE="offline copy: $CACHED snippets in $CACHE"
  else CACHE_NOTE="${RED}no offline copy — could not download the snippets${R}"; fi
elif [ "$(cache_age_days)" -ge "$CACHE_MAX_AGE_DAYS" ]; then
  CACHED=$(refresh_cache) || CACHED=""
  CACHE_NOTE="offline copy: $(cache_count) snippets in $CACHE"
else
  CACHE_NOTE="offline copy: $(cache_count) snippets, $(cache_age_days)d old"
fi

echo
echo "${CYAN}  Ubuntu Assistant${R} ${DIM}— Ubuntu Essentials, one pick away${R}"
echo "${DIM}  sico.securytik.com · github.com/mhdhaidarah/Ubuntu-Essentials${R}"
[ -n "$CACHE_NOTE" ] && echo "${DIM}  $CACHE_NOTE${R}"
if [ -n "$LAUNCHER_PATH" ]; then
  echo "${DIM}  next time just type${R} ${GREEN}$LAUNCHER_NAME${R} ${DIM}(or press ↑) — installed at $LAUNCHER_PATH${R}"
  case ":$PATH:" in
    *":$(dirname "$LAUNCHER_PATH"):"*) ;;
    *) echo "${DIM}  ($(dirname "$LAUNCHER_PATH") is not on your PATH yet — log out and back in)${R}" ;;
  esac
fi
echo

# Two columns, titles only. One line per item with its description was fine at
# 20 entries and unreadable past 40 — the list scrolled off the top of the
# terminal before you reached the prompt. Descriptions are still one keystroke
# away: `?N` prints the full entry for N. Narrow terminals fall back to one
# column, because wrapped columns are worse than a long list.
COLS=2
[ "${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}" -lt 76 ] && COLS=1

LAST_GROUP=""; col=0
for i in "${!ITEMS[@]}"; do
  IFS='|' read -r group file title desc <<< "${ITEMS[$i]}"
  if [ "$group" != "$LAST_GROUP" ]; then
    [ "$col" -ne 0 ] && { echo; col=0; }          # finish a half-filled row
    echo
    echo "  ${B}$group${R}"
    LAST_GROUP="$group"
  fi
  printf "    ${GREEN}%2d${R}) %-30s" "$((i+1))" "$title"
  col=$((col+1))
  [ "$col" -ge "$COLS" ] && { echo; col=0; }
done
[ "$col" -ne 0 ] && echo

echo

echo
echo "  ${DIM}?N shows what an entry does (e.g. ?15) · r re-downloads the offline copy${R}"
read -rp "  Pick a number (q to quit): " CHOICE

case "${CHOICE:-}" in
  r|R)
    echo "  ${DIM}refreshing from the repo...${R}"
    if CACHED=$(refresh_cache); then echo "  ${GREEN}offline copy updated — $CACHED snippets.${R}"
    else echo "  ${RED}Could not reach the repo. The existing copy is untouched.${R}"; fi
    CHOICE="" ;;
esac

# `?N` — show the full description for one entry, then stop. Keeps the menu
# compact without hiding what anything actually does.
case "${CHOICE:-}" in
  \?[0-9]*)
    n="${CHOICE#\?}"
    if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#ITEMS[@]}" ]; then
      IFS='|' read -r group file title desc <<< "${ITEMS[$((n-1))]}"
      echo; echo "  ${B}$title${R}  ${DIM}($group)${R}"
      echo "  $desc"
      echo "  ${DIM}$RAW/$file${R}"; echo
    else
      echo "  ${RED}No such item.${R}"
    fi
    CHOICE="" ;;
esac

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

  # The local copy first, and the network only when there isn't one. This is
  # what makes ssh-control, network-ip, dns-setup and the rest usable on a box
  # with no route out — which is exactly the box you are usually fixing.
  #
  # NOT `exec`: that replaced the assistant's process, so control never came
  # back here, and any snippet ending in `exec bash` (hostname.sh does, to pick
  # up the new name) replaced it again — between them they consumed the shell
  # the user started from. As a child it just returns here.
  if [ -r "$CACHE/$file" ]; then
    echo "  ${DIM}running $CACHE/$file${R}"; echo
    bash "$CACHE/$file"
  else
    echo "  ${DIM}running $RAW/$file${R}"; echo
    # Download, then run. Process substitution hands bash an EMPTY stream when
    # the fetch fails, which looks exactly like a snippet that did nothing.
    T=$(mktemp)
    if curl -fsSL --connect-timeout 8 -o "$T" "$RAW/$file" && [ -s "$T" ]; then
      cache_put "$file" "$T"        # next time it is here, network or not
      bash "$T"
    else
      echo "  ${RED}Not in the offline copy and the repo is unreachable.${R}"
      echo "  ${DIM}Connect once and pick r to download the snippets.${R}"
    fi
    rm -f "$T"
  fi
fi
