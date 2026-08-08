#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/user-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

list_users() {
  echo
  echo "Login-capable users:"
  echo "----------------------------------------------------------------------"
  printf "  %-18s %-8s %-10s %s\n" "USER" "UID" "SUDO" "SHELL"
  while IFS=: read -r name _ uid _ _ home shell; do
    case "$shell" in
      */bash|*/sh|*/zsh|*/ksh|*/fish)
        if id -nG "$name" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then SU="yes"; else SU="no"; fi
        printf "  %-18s %-8s %-10s %s\n" "$name" "$uid" "$SU" "$shell"
        ;;
    esac
  done < /etc/passwd
  echo "----------------------------------------------------------------------"
}

who_online() {
  echo
  echo "Currently logged in:"
  who 2>/dev/null | awk '{printf "  %-15s %-10s %s %s\n",$1,$2,$3,$4}' || true
}

add_user() {
  read -rp "New username: " U
  [ -z "$U" ] && { echo "Required."; return; }
  id "$U" >/dev/null 2>&1 && { echo "User already exists."; return; }
  read -rsp "Password (Enter to set later / key-only): " P; echo
  read -rp "Give sudo privileges? [y/N]: " S
  read -rp "Login shell [/bin/bash]: " SH; SH="${SH:-/bin/bash}"

  useradd -m -s "$SH" "$U"
  if [ -n "$P" ]; then echo "$U:$P" | chpasswd; echo "Password set."; else echo "No password set (use SSH key or 'passwd $U' later)."; fi
  if [ "$S" = "y" ] || [ "$S" = "Y" ]; then usermod -aG sudo "$U"; echo "Added to sudo group."; fi
  echo "User '$U' created."
}

del_user() {
  read -rp "Username to delete: " U
  [ -z "$U" ] && { echo "Required."; return; }
  id "$U" >/dev/null 2>&1 || { echo "No such user."; return; }
  [ "$U" = "root" ] && { echo "Refusing to delete root."; return; }
  if [ "$U" = "$(logname 2>/dev/null)" ]; then
    echo "That's the account you logged in with — refusing."
    return
  fi
  read -rp "Also delete home directory and mail? [y/N]: " H
  read -rp "Confirm delete '$U'? [y/N]: " C
  [ "$C" = "y" ] || [ "$C" = "Y" ] || { echo "Aborted."; return; }
  pkill -u "$U" 2>/dev/null || true; sleep 1
  if [ "$H" = "y" ] || [ "$H" = "Y" ]; then userdel -r "$U" 2>/dev/null || userdel "$U"; else userdel "$U"; fi
  echo "Deleted '$U'."
}

toggle_sudo() {
  read -rp "Username: " U
  id "$U" >/dev/null 2>&1 || { echo "No such user."; return; }
  if id -nG "$U" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
    read -rp "'$U' currently HAS sudo. Remove it? [y/N]: " R
    if [ "$R" = "y" ] || [ "$R" = "Y" ]; then
      deluser "$U" sudo 2>/dev/null || gpasswd -d "$U" sudo; echo "sudo removed."
    else echo "Unchanged."; fi
  else
    read -rp "'$U' has NO sudo. Grant it? [y/N]: " R
    if [ "$R" = "y" ] || [ "$R" = "Y" ]; then
      usermod -aG sudo "$U"; echo "sudo granted."
    else echo "Unchanged."; fi
  fi
}

list_users
who_online
echo
echo "  1) Add user"
echo "  2) Delete user"
echo "  3) Grant/revoke sudo"
echo "  4) Refresh list"
echo "  Enter) quit"
read -rp "Choice: " CH
case "$CH" in
  1) add_user ;;
  2) del_user ;;
  3) toggle_sudo ;;
  4) list_users; who_online ;;
  *) echo "Bye." ;;
esac
SCRIPT
chmod +x /usr/local/sbin/user-wizard
echo "Installed. Run:  sudo user-wizard"
EOF

sudo user-wizard
