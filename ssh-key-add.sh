#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/authkey-add <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# which account to add the key for
read -rp "Add key for which user? [root]: " TARGET
TARGET="${TARGET:-root}"
id "$TARGET" >/dev/null 2>&1 || { echo "User '$TARGET' does not exist."; exit 1; }

if [ "$TARGET" = "root" ]; then HOME_DIR="/root"; else HOME_DIR="/home/$TARGET"; fi
SSH_DIR="$HOME_DIR/.ssh"
AUTH="$SSH_DIR/authorized_keys"

echo
echo "Paste the PUBLIC key (one line, starts with ssh-ed25519 / ssh-rsa / ecdsa-...):"
read -rp "> " PUBKEY

# basic validation
if ! echo "$PUBKEY" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[a-z0-9-]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-[a-z0-9-]+@openssh.com) '; then
  echo "That does not look like a valid SSH public key. Aborting."; exit 1
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "$TARGET":"$TARGET" "$SSH_DIR"

# skip if already present
if [ -f "$AUTH" ] && grep -qF "$PUBKEY" "$AUTH"; then
  echo "Key already present in $AUTH — nothing to do."
  exit 0
fi

echo "$PUBKEY" >> "$AUTH"
chmod 600 "$AUTH"
chown "$TARGET":"$TARGET" "$AUTH"

echo
echo "Added to $AUTH"
echo "Fingerprint: $(echo "$PUBKEY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2, $3}')"
echo "Total keys now: $(wc -l < "$AUTH")"
SCRIPT
chmod +x /usr/local/sbin/authkey-add
echo "Installed. Run:  sudo authkey-add"
EOF

sudo authkey-add
