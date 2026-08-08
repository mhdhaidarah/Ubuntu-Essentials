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
SVC=$(systemctl list-unit-files 2>/dev/null | grep -qE '^ssh\.service' && echo ssh || echo sshd)

have_include() { grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN" 2>/dev/null; }

# --- read the EFFECTIVE value, not whatever a file says -----------------------
# sshd -T prints the config it would actually run with, after Includes and
# Match blocks. Grepping the files by hand gets this wrong the moment there are
# two of them, which is exactly when you need the answer to be right.
eff() { sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k {print $2; exit}'; }

show() {
  echo
  echo "Current effective SSH settings:"
  echo "----------------------------------------------------------------------"
  printf "  %-24s %s\n" "server installed:" "$(command -v sshd >/dev/null && echo yes || echo NO)"
  printf "  %-24s %s\n" "service:" "$(systemctl is-active $SVC 2>/dev/null) / $(systemctl is-enabled $SVC 2>/dev/null)"
  printf "  %-24s %s\n" "listening on:" "$(eff port)"
  printf "  %-24s %s\n" "PermitRootLogin:" "$(eff permitrootlogin)"
  printf "  %-24s %s\n" "PasswordAuthentication:" "$(eff passwordauthentication)"
  printf "  %-24s %s\n" "PubkeyAuthentication:" "$(eff pubkeyauthentication)"
  printf "  %-24s %s\n" "KbdInteractive:" "$(eff kbdinteractiveauthentication)"
  [ -f "$DROPIN" ] && printf "  %-24s %s\n" "our drop-in:" "$DROPIN" \
                   || printf "  %-24s %s\n" "our drop-in:" "(none — stock config)"
  echo "----------------------------------------------------------------------"
}

# --- who could still get in with keys? ---------------------------------------
# Asked before we ever turn passwords off. Counting root plus every /home user
# with a non-empty authorized_keys; that set becoming empty is a locked door.
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

# --- apply, but never leave a broken config behind ---------------------------
apply() {
  local body="$1"
  mkdir -p "$DROPIN_DIR"
  local bk=""
  [ -f "$DROPIN" ] && { bk="${DROPIN}.bak.$(date +%Y%m%d%H%M%S)"; cp "$DROPIN" "$bk"; }

  if have_include; then
    printf '# Written by ssh-control. Remove this file to return to defaults.\n%s\n' "$body" > "$DROPIN"
  else
    # Old release with no Include line: add one rather than editing directives
    # in place, so the vendor file still only gains a single line.
    echo "Include $DROPIN_DIR/*.conf" | cat - "$MAIN" > "$MAIN.new" && mv "$MAIN.new" "$MAIN"
    printf '# Written by ssh-control. Remove this file to return to defaults.\n%s\n' "$body" > "$DROPIN"
  fi

  # Validate BEFORE reloading. A syntax error that reaches a running sshd is how
  # people lock themselves out of a remote box for good.
  if ! sshd -t 2>/tmp/sshd-test.$$; then
    echo
    echo "REFUSING TO APPLY — sshd rejected the config:"
    sed 's/^/    /' /tmp/sshd-test.$$; rm -f /tmp/sshd-test.$$
    if [ -n "$bk" ]; then mv "$bk" "$DROPIN"; echo "Previous drop-in restored."
    else rm -f "$DROPIN"; echo "Drop-in removed; you are back on the stock config."; fi
    return 1
  fi
  rm -f /tmp/sshd-test.$$ "$bk" 2>/dev/null || true

  systemctl reload "$SVC" 2>/dev/null || systemctl restart "$SVC"
  echo "Applied and reloaded. YOUR CURRENT SESSION STAYS OPEN — test a NEW one"
  echo "in a second terminal before you close this window."
  return 0
}

install_ssh() {
  if command -v sshd >/dev/null; then
    echo "OpenSSH server is already installed."
  else
    echo "Installing openssh-server..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  fi
  systemctl enable --now "$SVC"
  echo "Service: $(systemctl is-active $SVC) / $(systemctl is-enabled $SVC)"
  command -v ufw >/dev/null && ufw status 2>/dev/null | grep -qi "Status: active" && {
    read -rp "ufw is active. Allow OpenSSH through it? [Y/n]: " A
    [ "$A" = "n" ] || [ "$A" = "N" ] || ufw allow OpenSSH >/dev/null 2>&1 && echo "ufw: OpenSSH allowed."
  }
}

restore_default() {
  echo
  echo "This removes every change ssh-control has made and returns you to the"
  echo "distribution's own SSH configuration."
  read -rp "Continue? [y/N]: " C
  [ "$C" = "y" ] || [ "$C" = "Y" ] || { echo "Aborted."; return; }
  if [ -f "$DROPIN" ]; then
    mv "$DROPIN" "${DROPIN}.removed.$(date +%Y%m%d%H%M%S)"
    echo "Drop-in removed (kept alongside with a .removed suffix)."
  else
    echo "No ssh-control drop-in present — nothing of ours to undo."
  fi
  if sshd -t 2>/dev/null; then
    systemctl reload "$SVC" 2>/dev/null || systemctl restart "$SVC"
    echo "Reloaded on the stock configuration."
  else
    echo "WARNING: the remaining config does not validate — someone edited"
    echo "$MAIN by hand. Not reloading. Fix it, then: systemctl reload $SVC"
  fi
}

root_access() {
  echo
  echo "PermitRootLogin is currently: $(eff permitrootlogin)"
  echo
  echo "  1) yes              — root may log in, password or key"
  echo "  2) prohibit-password— root may log in by KEY only  (recommended)"
  echo "  3) no               — root may not log in at all   (safest)"
  echo "  Enter) cancel"
  read -rp "Choice: " R
  case "$R" in
    1) V=yes ;;
    2) V=prohibit-password ;;
    3) V=no ;;
    *) echo "Unchanged."; return ;;
  esac

  if [ "$V" = "yes" ]; then
    echo
    echo "Allowing root login with a PASSWORD exposes the one account every"
    echo "brute-force list starts with. Prefer option 2 if you have a key."
    read -rp "Type YES to confirm: " C
    [ "$C" = "YES" ] || { echo "Aborted."; return; }
  fi

  if [ "$V" = "no" ]; then
    # Refusing root everywhere is only safe if somebody else can still escalate.
    if ! awk -F: '$1!="root" && $3>=1000 && $7 ~ /(bash|sh|zsh|ksh|fish)$/ {print $1}' /etc/passwd \
         | while read -r u; do id -nG "$u" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel' && echo "$u"; done | grep -q .; then
      echo
      echo "REFUSING: no non-root user with sudo exists, so disabling root login"
      echo "would leave nobody able to administer this machine."
      echo "Create one first (user-manage.sh), then come back."
      return
    fi
  fi
  apply "PermitRootLogin $V" && echo "PermitRootLogin is now: $(eff permitrootlogin)"
}

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
    1) PW=yes; PK=no  ;;
    2) PW=no;  PK=yes ;;
    3) PW=yes; PK=yes ;;
    *) echo "Unchanged."; return ;;
  esac

  # THE lockout case: turning passwords off with no key installed anywhere means
  # the next disconnect is permanent. Checked before it is possible to say yes.
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

  # KbdInteractive follows PasswordAuthentication: leaving it on is a second,
  # quieter password path, so "key only" would not actually be key only.
  apply "PasswordAuthentication $PW
PubkeyAuthentication $PK
KbdInteractiveAuthentication $PW" \
    && echo "Now: password=$(eff passwordauthentication)  pubkey=$(eff pubkeyauthentication)"
}

if ! command -v sshd >/dev/null; then
  echo "OpenSSH server is not installed on this machine yet."
else
  show
fi

echo
echo "  1) Install / enable the SSH server"
echo "  2) Restore the default SSH configuration"
echo "  3) Root login policy"
echo "  4) Login method (password / key / both)"
echo "  5) Show current settings"
echo "  Enter) quit"
read -rp "Choice: " CH
case "$CH" in
  1) install_ssh ;;
  2) restore_default ;;
  3) root_access ;;
  4) login_model ;;
  5) show ;;
  *) echo "Nothing to do." ;;
esac
SCRIPT
chmod +x /usr/local/sbin/ssh-control
echo "Installed. Run:  sudo ssh-control"
EOF

sudo ssh-control
