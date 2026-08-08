#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/ssh-control <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# Every change goes into a drop-in, never into the stock sshd_config. Ubuntu
# ships `Include /etc/ssh/sshd_config.d/*.conf` at the TOP of sshd_config, and
# sshd takes the FIRST occurrence of a keyword — so a drop-in wins, the vendor
# file stays pristine, and "restore defaults" is one file removal instead of
# trying to un-edit somebody's sed.
DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="$DROPIN_DIR/99-ssh-control.conf"
MAIN=/etc/ssh/sshd_config
BKDIR=/var/backups/ssh-control
SVC=$(systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service' && echo ssh || echo sshd)

have_include() { grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN" 2>/dev/null; }

# Ubuntu 22.10+ can run sshd from a SOCKET. When it does, sshd_config's Port is
# ignored entirely — the socket decides what to listen on — so changing Port
# there looks like it worked and silently does nothing.
socket_mode() { systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-enabled ssh.socket >/dev/null 2>&1; }

# Read the EFFECTIVE value, not whatever a file says. `sshd -T` prints the
# config sshd would actually run with, after Includes and Match blocks;
# grepping the files by hand stops being right the moment there are two.
eff() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k {print $2; exit}'; }
eff_all() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k {$1=""; sub(/^ /,""); print}'; }

# `systemctl show -p ListenStream` returns NOTHING on some systemd versions even
# when the socket plainly has one, so read the merged unit with `systemctl cat`
# (drop-ins included, last non-empty wins — our override clears then sets) and
# fall through to sshd -T, then to 22, rather than ever printing an empty port.
cur_port() {
  local p=""
  if socket_mode; then
    p=$(systemctl cat ssh.socket 2>/dev/null | grep -E '^ListenStream=..*' | tail -1 | sed 's/.*://')
  fi
  [ -z "$p" ] && p=$(eff port)
  [ -z "$p" ] && p=22
  echo "$p"
}

show() {
  echo
  echo "Current effective SSH settings:"
  echo "----------------------------------------------------------------------"
  printf "  %-26s %s\n" "server installed:" "$(command -v sshd >/dev/null && echo yes || echo NO)"
  printf "  %-26s %s\n" "service:" "$(systemctl is-active $SVC 2>/dev/null) / $(systemctl is-enabled $SVC 2>/dev/null)"
  printf "  %-26s %s\n" "socket-activated:" "$(socket_mode && echo 'YES (ssh.socket owns the port)' || echo no)"
  printf "  %-26s %s\n" "listening on port:" "$(cur_port)"
  printf "  %-26s %s\n" "PermitRootLogin:" "$(eff permitrootlogin)"
  printf "  %-26s %s\n" "PasswordAuthentication:" "$(eff passwordauthentication)"
  printf "  %-26s %s\n" "PubkeyAuthentication:" "$(eff pubkeyauthentication)"
  printf "  %-26s %s\n" "KbdInteractive:" "$(eff kbdinteractiveauthentication)"
  printf "  %-26s %s\n" "ClientAliveInterval:" "$(eff clientaliveinterval)"
  printf "  %-26s %s\n" "ClientAliveCountMax:" "$(eff clientalivecountmax)"
  # Every one of these MUST end in `|| true`. This function runs under `set -e`,
  # and `var=$(cmd)` takes cmd's exit status — `systemctl is-active fail2ban`
  # exits 4 when it is inactive, which silently killed show() half way down the
  # list, printing nothing at all for the rows below it.
  local au ag f2b
  au=$(eff_all allowusers) || true
  ag=$(eff_all allowgroups) || true
  # is-active also PRINTS "inactive" while failing, so a bare `|| echo ...`
  # appended a second line instead of replacing the first.
  f2b=$(systemctl is-active fail2ban 2>/dev/null) || true
  command -v fail2ban-server >/dev/null || f2b="not installed"
  printf "  %-26s %s\n" "AllowUsers:" "${au:-(everyone)}"
  printf "  %-26s %s\n" "AllowGroups:" "${ag:-(everyone)}"
  printf "  %-26s %s\n" "fail2ban:" "${f2b:-unknown}"
  [ -f "$DROPIN" ] && printf "  %-26s %s\n" "our drop-in:" "$DROPIN" \
                   || printf "  %-26s %s\n" "our drop-in:" "(none — stock config)"
  echo "----------------------------------------------------------------------"
}

# Who could still get in with keys? Asked before passwords are ever turned off;
# that set becoming empty is a locked door.
key_users() {
  local u f n=0
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    grep -qvE '^\s*($|#)' "$f" 2>/dev/null || continue
    u=$(echo "$f" | awk -F/ '{print ($2=="root")?"root":$3}')
    echo "    $u ($(grep -cvE '^\s*($|#)' "$f") key(s))"
    n=$((n+1))
  done
  return $((n==0))
}

sudo_users() {
  awk -F: '$1!="root" && $3>=1000 && $7 ~ /(bash|sh|zsh|ksh|fish)$/ {print $1}' /etc/passwd \
   | while read -r u; do id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel' && echo "$u"; done
}

# --- apply, but never leave a broken config behind ---------------------------
apply() {
  local body="$1"
  mkdir -p "$DROPIN_DIR"
  local bk=""
  [ -f "$DROPIN" ] && { bk="${DROPIN}.bak.$$"; cp "$DROPIN" "$bk"; }

  if ! have_include; then
    # Old release with no Include line: add one rather than editing directives
    # in place, so the vendor file still only gains a single line.
    echo "Include $DROPIN_DIR/*.conf" | cat - "$MAIN" > "$MAIN.new" && mv "$MAIN.new" "$MAIN"
  fi
  printf '# Written by ssh-control. Remove this file to return to defaults.\n%s\n' "$body" > "$DROPIN"

  # Validate BEFORE reloading. A syntax error reaching a running sshd is how
  # people lose a remote box for good.
  if ! sshd -t 2>/tmp/sshd-test.$$; then
    echo
    echo "REFUSING TO APPLY — sshd rejected the config:"
    sed 's/^/    /' /tmp/sshd-test.$$; rm -f /tmp/sshd-test.$$
    if [ -n "$bk" ]; then mv "$bk" "$DROPIN"; echo "Previous drop-in restored."
    else rm -f "$DROPIN"; echo "Drop-in removed; you are back on the stock config."; fi
    return 1
  fi
  rm -f /tmp/sshd-test.$$; [ -n "$bk" ] && rm -f "$bk"

  systemctl reload "$SVC" 2>/dev/null || systemctl restart "$SVC"
  echo "Applied and reloaded. YOUR CURRENT SESSION STAYS OPEN — test a NEW one"
  echo "in a second terminal before you close this window."
  return 0
}

# Merge a directive into the existing drop-in, replacing any previous value of
# the same keyword. Each feature owns its keywords without clobbering the others.
set_directives() {
  local tmp; tmp=$(mktemp)
  [ -f "$DROPIN" ] && grep -vE "^[[:space:]]*($1)[[:space:]]" "$DROPIN" | grep -v '^#' > "$tmp" || true
  shift
  printf '%s\n' "$@" >> "$tmp"
  local body; body=$(grep -vE '^\s*$' "$tmp"); rm -f "$tmp"
  apply "$body"
}

# ============================ 1. install =====================================
install_ssh() {
  if command -v sshd >/dev/null; then
    echo "OpenSSH server is already installed."
  else
    echo "Installing openssh-server..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  fi
  systemctl enable --now "$SVC" 2>/dev/null || true
  socket_mode && systemctl enable --now ssh.socket 2>/dev/null || true
  echo "Service: $(systemctl is-active $SVC) / $(systemctl is-enabled $SVC)"
  open_firewall "$(cur_port)"
}

# ============================ 2. restore =====================================
restore_default() {
  echo
  echo "This removes every change ssh-control has made and returns you to the"
  echo "distribution's own SSH configuration."
  read -rp "Continue? [y/N]: " C
  [ "$C" = "y" ] || [ "$C" = "Y" ] || { echo "Aborted."; return; }
  backup_config "before-restore"
  if [ -f "$DROPIN" ]; then
    rm -f "$DROPIN"; echo "Drop-in removed."
  else
    echo "No ssh-control drop-in present — nothing of ours to undo."
  fi
  if [ -f /etc/systemd/system/ssh.socket.d/ssh-control.conf ]; then
    rm -f /etc/systemd/system/ssh.socket.d/ssh-control.conf
    systemctl daemon-reload; echo "Socket port override removed."
  fi
  if sshd -t 2>/dev/null; then
    systemctl restart "$SVC" 2>/dev/null || true
    socket_mode && systemctl restart ssh.socket 2>/dev/null || true
    echo "Reloaded on the stock configuration (port $(cur_port))."
  else
    echo "WARNING: the remaining config does not validate — someone edited"
    echo "$MAIN by hand. Not reloading. Fix it, then: systemctl reload $SVC"
  fi
}

# ============================ 3. root login ==================================
root_access() {
  echo
  echo "PermitRootLogin is currently: $(eff permitrootlogin)"
  echo
  echo "  1) yes               — root may log in, password or key"
  echo "  2) prohibit-password — root may log in by KEY only  (recommended)"
  echo "  3) no                — root may not log in at all   (safest)"
  echo "  Enter) cancel"
  read -rp "Choice: " R
  case "$R" in
    1) V=yes ;; 2) V=prohibit-password ;; 3) V=no ;;
    *) echo "Unchanged."; return ;;
  esac
  if [ "$V" = "yes" ]; then
    echo
    echo "Allowing root login with a PASSWORD exposes the one account every"
    echo "brute-force list starts with. Prefer option 2 if you have a key."
    read -rp "Type YES to confirm: " C
    [ "$C" = "YES" ] || { echo "Aborted."; return; }
  fi
  if [ "$V" = "no" ] && [ -z "$(sudo_users)" ]; then
    echo
    echo "REFUSING: no non-root user with sudo exists, so disabling root login"
    echo "would leave nobody able to administer this machine."
    echo "Create one first (user-manage.sh), then come back."
    return
  fi
  set_directives "PermitRootLogin" "PermitRootLogin $V" \
    && echo "PermitRootLogin is now: $(eff permitrootlogin)"
}

# ============================ 4. login model =================================
login_model() {
  echo
  echo "Currently: password=$(eff passwordauthentication)  pubkey=$(eff pubkeyauthentication)"
  echo
  echo "  1) Password only"
  echo "  2) Key only          (most secure)"
  echo "  3) Password or key   (either one gets you in)"
  echo "  Enter) cancel"
  read -rp "Choice: " M
  case "$M" in
    1) PW=yes; PK=no  ;; 2) PW=no;  PK=yes ;; 3) PW=yes; PK=yes ;;
    *) echo "Unchanged."; return ;;
  esac
  if [ "$PW" = "no" ]; then
    echo
    echo "Accounts that could still log in by key:"
    if ! key_users; then
      echo "    (none)"
      echo
      echo "REFUSING: no authorized_keys anywhere on this system. Turning"
      echo "passwords off now would lock you out the moment you disconnect."
      echo "Install a key first — ssh-key-add.sh — then come back."
      return
    fi
    echo
    read -rp "Those are the ONLY ways in afterwards. Type KEYONLY to confirm: " C
    [ "$C" = "KEYONLY" ] || { echo "Aborted."; return; }
  fi
  if [ "$PK" = "no" ]; then
    echo
    echo "Disabling public-key auth means every existing key stops working."
    read -rp "Continue? [y/N]: " C
    [ "$C" = "y" ] || [ "$C" = "Y" ] || { echo "Aborted."; return; }
  fi
  # KbdInteractive follows PasswordAuthentication: left on, it is a second and
  # quieter password path, so "key only" would not actually be key only.
  set_directives "PasswordAuthentication|PubkeyAuthentication|KbdInteractiveAuthentication" \
    "PasswordAuthentication $PW" "PubkeyAuthentication $PK" "KbdInteractiveAuthentication $PW" \
    && echo "Now: password=$(eff passwordauthentication)  pubkey=$(eff pubkeyauthentication)"
}

# ============================ 5. port ========================================
open_firewall() {
  local p="$1"
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi "Status: active"; then
    ufw allow "$p"/tcp >/dev/null 2>&1 && echo "  ufw: allowed $p/tcp"
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && echo "  firewalld: allowed $p/tcp"
  fi
  if command -v semanage >/dev/null; then
    semanage port -a -t ssh_port_t -p tcp "$p" 2>/dev/null \
      || semanage port -m -t ssh_port_t -p tcp "$p" 2>/dev/null
  fi
}

change_port() {
  local now; now=$(cur_port)
  echo
  echo "SSH is currently reachable on port $now."
  socket_mode && echo "NOTE: this box is SOCKET-activated, so the port lives in ssh.socket," \
              && echo "      not sshd_config. Handled below."
  read -rp "New port (1-65535, Enter to cancel): " P
  [ -z "$P" ] && { echo "Unchanged."; return; }
  case "$P" in ''|*[!0-9]*) echo "Not a number."; return ;; esac
  [ "$P" -lt 1 ] || [ "$P" -gt 65535 ] && { echo "Out of range."; return; }
  if ss -lntH "sport = :$P" 2>/dev/null | grep -q . && [ "$P" != "$now" ]; then
    echo "REFUSING: something is already listening on port $P:"
    ss -lntpH "sport = :$P" 2>/dev/null | sed 's/^/    /' | head -3
    return
  fi

  # Firewall FIRST. Opening it after the reload leaves a window where the new
  # port is live and blocked, and the old one is already gone.
  echo "Opening the firewall for $P before touching sshd..."
  open_firewall "$P"

  if socket_mode; then
    mkdir -p /etc/systemd/system/ssh.socket.d
    # ListenStream= (empty) first: without clearing it, the new port is ADDED
    # to the old one rather than replacing it.
    printf '[Socket]\nListenStream=\nListenStream=%s\n' "$P" \
      > /etc/systemd/system/ssh.socket.d/ssh-control.conf
    systemctl daemon-reload
    if systemctl restart ssh.socket 2>/dev/null; then
      echo "ssh.socket now listens on $P."
    else
      rm -f /etc/systemd/system/ssh.socket.d/ssh-control.conf
      systemctl daemon-reload; systemctl restart ssh.socket 2>/dev/null || true
      echo "REFUSED: ssh.socket would not start on $P. Reverted to $now."; return
    fi
  else
    set_directives "Port" "Port $P" || return
  fi

  echo
  echo "Now listening on: $(cur_port)"
  ss -lntH 2>/dev/null | awk -v p=":$P" '$4 ~ p {print "    " $4}' | head -3
  echo
  echo "KEEP THIS SESSION OPEN. Test from another terminal first:"
  echo "    ssh -p $P $(logname 2>/dev/null || echo root)@<this-host>"
  echo "If it fails you still have this window to run option 2 (restore)."
}

# ============================ 6. fail2ban ====================================
setup_fail2ban() {
  echo
  if ! command -v fail2ban-server >/dev/null; then
    read -rp "fail2ban is not installed. Install it? [Y/n]: " I
    [ "$I" = "n" ] || [ "$I" = "N" ] && { echo "Skipped."; return; }
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
  fi
  local port; port=$(cur_port)
  read -rp "Ban after how many failures? [5]: " MAXR; MAXR="${MAXR:-5}"
  read -rp "Ban for how long (e.g. 10m, 1h, 1d)? [1h]: " BT; BT="${BT:-1h}"
  read -rp "Never ban these IPs (space separated, Enter for none): " IGN

  # jail.local, never jail.conf — the package owns jail.conf and replaces it on
  # upgrade. Ubuntu's fail2ban reads the journal, not /var/log/auth.log, which
  # on a systemd box is often empty and makes the jail silently match nothing.
  cat > /etc/fail2ban/jail.local <<J
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 $IGN

[sshd]
enabled  = true
port     = $port
backend  = systemd
maxretry = $MAXR
bantime  = $BT
findtime = 10m
J
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  sleep 2
  echo
  fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || echo "  (jail not up yet — check: fail2ban-client status sshd)"
  echo
  echo "Unban an address later with:  fail2ban-client set sshd unbanip <IP>"
}

# ============================ 7. allow list ==================================
restrict_login() {
  echo
  local _au _ag; _au=$(eff_all allowusers) || true; _ag=$(eff_all allowgroups) || true
  echo "Currently AllowUsers:  ${_au:-(everyone)}"
  echo "Currently AllowGroups: ${_ag:-(everyone)}"
  echo
  echo "  1) Limit to specific USERS"
  echo "  2) Limit to a GROUP"
  echo "  3) Remove all restrictions (everyone may log in)"
  echo "  Enter) cancel"
  read -rp "Choice: " R
  case "$R" in
    1) read -rp "Usernames, space separated: " L
       [ -z "$L" ] && { echo "Nothing given."; return; }
       for u in $L; do id "$u" >/dev/null 2>&1 || { echo "No such user: $u"; return; }; done
       # Stranding guard: the account you are on right now must survive the rule.
       ME=$(logname 2>/dev/null || echo root)
       echo "$L" | tr ' ' '\n' | grep -qxF "$ME" || {
         echo
         echo "WARNING: '$ME' — the account this session belongs to — is NOT in that list."
         read -rp "Type STRAND to accept being locked out: " C
         [ "$C" = "STRAND" ] || { echo "Aborted."; return; }
       }
       set_directives "AllowUsers|AllowGroups" "AllowUsers $L" ;;
    2) read -rp "Group name: " G
       getent group "$G" >/dev/null || { echo "No such group."; return; }
       [ -z "$(getent group "$G" | cut -d: -f4)" ] && echo "NOTE: '$G' currently has no members."
       ME=$(logname 2>/dev/null || echo root)
       id -nG "$ME" 2>/dev/null | tr ' ' '\n' | grep -qxF "$G" || {
         echo
         echo "WARNING: '$ME' is not in group '$G' and would be locked out."
         read -rp "Type STRAND to accept: " C
         [ "$C" = "STRAND" ] || { echo "Aborted."; return; }
       }
       set_directives "AllowUsers|AllowGroups" "AllowGroups $G" ;;
    3) set_directives "AllowUsers|AllowGroups" "# no login restrictions" ;;
    *) echo "Unchanged."; return ;;
  esac
  _au=$(eff_all allowusers) || true; _ag=$(eff_all allowgroups) || true
  echo "AllowUsers now:  ${_au:-(everyone)}"
  echo "AllowGroups now: ${_ag:-(everyone)}"
}

# ============================ 8. who / attempts ==============================
sessions_report() {
  echo
  echo "Logged in right now:"
  who 2>/dev/null | sed 's/^/    /' || echo "    (none)"
  echo
  echo "Established SSH connections:"
  ss -tnpH state established "( sport = :$(cur_port) )" 2>/dev/null \
    | awk '{print "    " $4 "  <-  " $5}' | head -10 || echo "    (none)"
  echo
  echo "Last 10 logins:"
  last -n 10 2>/dev/null | head -10 | sed 's/^/    /'
  echo
  echo "Failed attempts in the last 24h, by source:"
  { journalctl -u "$SVC" --since "24 hours ago" 2>/dev/null || cat /var/log/auth.log 2>/dev/null; } \
    | grep -aiE "failed password|invalid user|authentication failure" \
    | grep -aoE "from [0-9a-fA-F:.]+" | awk '{print $2}' | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "    %6d  %s\n", $1, $2}'
  local n
  n=$({ journalctl -u "$SVC" --since "24 hours ago" 2>/dev/null || cat /var/log/auth.log 2>/dev/null; } \
      | grep -aciE "failed password|invalid user" || true)
  echo "    ---- ${n:-0} failed attempts total"
  if [ "${n:-0}" -gt 100 ]; then
    echo
    echo "  That is a lot. Consider option 6 (fail2ban) and key-only login."
  fi
  command -v fail2ban-client >/dev/null && { echo; echo "fail2ban:"; fail2ban-client status sshd 2>/dev/null | sed 's/^/    /'; }
}

# ============================ 9. idle timeout ================================
idle_timeout() {
  echo
  echo "Currently: ClientAliveInterval=$(eff clientaliveinterval)  ClientAliveCountMax=$(eff clientalivecountmax)"
  echo "(0 means never time out. Interval x CountMax = how long a dead session lingers.)"
  read -rp "Seconds between keepalives [300, 0 to disable]: " I; I="${I:-300}"
  case "$I" in ''|*[!0-9]*) echo "Not a number."; return ;; esac
  if [ "$I" = "0" ]; then
    set_directives "ClientAliveInterval|ClientAliveCountMax" "ClientAliveInterval 0" \
      && echo "Idle timeout disabled."
    return
  fi
  read -rp "How many missed keepalives before disconnect [2]: " C; C="${C:-2}"
  case "$C" in ''|*[!0-9]*) echo "Not a number."; return ;; esac
  set_directives "ClientAliveInterval|ClientAliveCountMax" \
    "ClientAliveInterval $I" "ClientAliveCountMax $C" \
    && echo "Idle sessions now drop after about $((I*C))s ($I x $C)."
}

# ============================ 10. host keys ==================================
regen_host_keys() {
  echo
  echo "Host keys identify THIS SERVER to clients. Regenerating them means every"
  echo "client that has connected before gets a loud"
  echo "  'REMOTE HOST IDENTIFICATION HAS CHANGED'"
  echo "warning and refuses to connect until they remove the old entry with:"
  echo "  ssh-keygen -R <this-host>"
  echo
  echo "Do it when this machine was cloned from an image (so it shares its keys"
  echo "with every other clone), or if the private keys may have leaked."
  echo
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | sed 's/^/  current: /'
  read -rp "Type REGEN to confirm: " C
  [ "$C" = "REGEN" ] || { echo "Aborted."; return; }
  backup_config "before-hostkey-regen"
  rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
  ssh-keygen -A
  if sshd -t 2>/dev/null; then
    systemctl restart "$SVC"
    echo "New host keys generated:"
    for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f" 2>/dev/null | sed 's/^/  /'; done
    echo
    echo "Tell anyone who connects here to run:  ssh-keygen -R <this-host>"
  else
    echo "sshd will not validate after regeneration — restoring the backup."
    restore_backup_latest
  fi
}

# ============================ 11. backup / restore ===========================
backup_config() {
  mkdir -p "$BKDIR"
  local tag="${1:-manual}" f="$BKDIR/ssh-$(date +%Y%m%d%H%M%S)-${1:-manual}.tar.gz"
  tar czf "$f" -C / etc/ssh 2>/dev/null
  chmod 600 "$f"
  echo "  backup: $f"
}

restore_backup_latest() {
  local f; f=$(ls -t "$BKDIR"/ssh-*.tar.gz 2>/dev/null | head -1)
  [ -z "$f" ] && { echo "No backup to restore."; return 1; }
  tar xzf "$f" -C /
  sshd -t 2>/dev/null && { systemctl restart "$SVC"; echo "Restored $f"; } \
    || echo "Restored $f but it does not validate — inspect $MAIN by hand."
}

backup_menu() {
  mkdir -p "$BKDIR"
  echo
  echo "Backups in $BKDIR:"
  local i=0; local -a L=()
  while read -r f; do [ -n "$f" ] || continue; i=$((i+1)); L+=("$f")
    printf "  %2d) %s  (%s)\n" "$i" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  done < <(ls -t "$BKDIR"/ssh-*.tar.gz 2>/dev/null)
  [ "$i" -eq 0 ] && echo "  (none yet)"
  echo
  echo "  b) take a backup now"
  echo "  number) restore that backup"
  echo "  Enter) cancel"
  read -rp "Choice: " C
  case "$C" in
    b|B) backup_config manual; echo "Done." ;;
    ''|*[!0-9]*) echo "Nothing to do." ;;
    *) local f="${L[$((C-1))]}"
       [ -z "$f" ] && { echo "No such backup."; return; }
       echo "Restoring $(basename "$f") — this replaces ALL of /etc/ssh."
       read -rp "Type RESTORE to confirm: " Y
       [ "$Y" = "RESTORE" ] || { echo "Aborted."; return; }
       backup_config before-restore
       tar xzf "$f" -C /
       if sshd -t 2>/dev/null; then systemctl restart "$SVC"; echo "Restored. Port is now $(cur_port)."
       else echo "WARNING: restored config does not validate. Not restarting sshd."; fi ;;
  esac
}

# ================================ menu =======================================
if ! command -v sshd >/dev/null; then
  echo "OpenSSH server is not installed on this machine yet."
else
  show
fi

echo
echo "   1) Install / enable the SSH server"
echo "   2) Restore the default SSH configuration"
echo "   3) Root login policy"
echo "   4) Login method (password / key / both)"
echo "   5) Change the SSH port"
echo "   6) Brute-force protection (fail2ban)"
echo "   7) Restrict who may log in"
echo "   8) Sessions and failed attempts"
echo "   9) Idle timeout"
echo "  10) Regenerate host keys"
echo "  11) Backup / restore the SSH config"
echo "  12) Show current settings"
echo "  Enter) quit"
read -rp "Choice: " CH
case "$CH" in
  1) install_ssh ;;
  2) restore_default ;;
  3) root_access ;;
  4) login_model ;;
  5) change_port ;;
  6) setup_fail2ban ;;
  7) restrict_login ;;
  8) sessions_report ;;
  9) idle_timeout ;;
  10) regen_host_keys ;;
  11) backup_menu ;;
  12) show ;;
  *) echo "Nothing to do." ;;
esac
SCRIPT
chmod +x /usr/local/sbin/ssh-control
echo "Installed. Run:  sudo ssh-control"
EOF

sudo ssh-control
