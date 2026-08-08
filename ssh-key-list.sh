#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/authkey-list <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

read -rp "Which user's keys? [root]: " TARGET
TARGET="${TARGET:-root}"
id "$TARGET" >/dev/null 2>&1 || { echo "User '$TARGET' does not exist."; exit 1; }

if [ "$TARGET" = "root" ]; then HOME_DIR="/root"; else HOME_DIR="/home/$TARGET"; fi
AUTH="$HOME_DIR/.ssh/authorized_keys"

[ -f "$AUTH" ] || { echo "No authorized_keys file for $TARGET ($AUTH)."; exit 0; }

# load non-empty, non-comment lines
mapfile -t KEYS < <(grep -vE '^\s*($|#)' "$AUTH")
[ "${#KEYS[@]}" -eq 0 ] && { echo "No keys in $AUTH."; exit 0; }

echo
echo "Authorized keys for $TARGET:"
echo "----------------------------------------------------------------------"
for i in "${!KEYS[@]}"; do
  LINE="${KEYS[$i]}"
  FP=$(echo "$LINE" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
  TYPE=$(echo "$LINE" | awk '{print $1}')
  CMT=$(echo "$LINE" | awk '{$1=$2=""; sub(/^ +/,""); print}')
  printf "  %2d) %-12s %s  %s\n" "$((i+1))" "$TYPE" "${FP:-?}" "${CMT:-(no comment)}"
done
echo "----------------------------------------------------------------------"
echo
echo "  number) remove that key"
echo "  a) remove ALL keys"
echo "  Enter) quit without changes"
read -rp "Choice: " C
[ -z "$C" ] && { echo "No changes."; exit 0; }

BK="${AUTH}.bak.$(date +%Y%m%d%H%M%S)"
cp "$AUTH" "$BK"

if [ "$C" = "a" ]; then
  read -rp "Remove ALL ${#KEYS[@]} keys for $TARGET? [y/N]: " YES
  [ "$YES" = "y" ] || [ "$YES" = "Y" ] || { echo "Aborted."; rm -f "$BK"; exit 0; }
  : > "$AUTH"
  echo "All keys removed. Backup: $BK"
else
  IDX=$((C-1))
  TARGET_KEY="${KEYS[$IDX]}"
  [ -z "$TARGET_KEY" ] && { echo "Invalid choice."; rm -f "$BK"; exit 1; }
  FP=$(echo "$TARGET_KEY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
  read -rp "Remove key #$C ($FP)? [y/N]: " YES
  [ "$YES" = "y" ] || [ "$YES" = "Y" ] || { echo "Aborted."; rm -f "$BK"; exit 0; }
  # rewrite file without the exact matching line
  grep -vxF "$TARGET_KEY" "$AUTH" > "$AUTH.tmp" && mv "$AUTH.tmp" "$AUTH"
  echo "Removed key #$C. Backup: $BK"
fi

chmod 600 "$AUTH"
chown "$TARGET":"$TARGET" "$AUTH"
echo "Remaining keys: $(grep -cvE '^\s*($|#)' "$AUTH")"
SCRIPT
chmod +x /usr/local/sbin/authkey-list
echo "Installed. Run:  sudo authkey-list"
EOF

sudo authkey-list
