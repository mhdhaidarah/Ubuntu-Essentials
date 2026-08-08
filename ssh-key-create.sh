#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/sshkey-gen <<'SCRIPT'
#!/bin/bash
set -e

# Runs as the invoking user (keys belong in that user's ~/.ssh), not forced root.
read -rp "Comment/label for the key [$(whoami)@$(hostname)]: " CMT
CMT="${CMT:-$(whoami)@$(hostname)}"
read -rp "Key name [id_ed25519]: " KN
KN="${KN:-id_ed25519}"

KEYDIR="$HOME/.ssh"
KEY="$KEYDIR/$KN"
mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"

if [ -f "$KEY" ]; then
  echo "Key $KEY already exists."
  read -rp "Overwrite? [y/N]: " OW
  [ "$OW" = "y" ] || [ "$OW" = "Y" ] || { echo "Keeping existing key."; PUB="$KEY.pub"; }
fi

if [ ! -f "$KEY" ] || [ "$OW" = "y" ] || [ "$OW" = "Y" ]; then
  read -rsp "Passphrase (Enter for none): " PP; echo
  ssh-keygen -t ed25519 -C "$CMT" -f "$KEY" -N "$PP"
fi

PUB="$KEY.pub"
PUBKEY="$(cat "$PUB")"

echo
echo "======================================================================"
echo "PUBLIC KEY ($PUB):"
echo "----------------------------------------------------------------------"
echo "$PUBKEY"
echo "======================================================================"
echo
echo "Add it to the REMOTE server one of these ways:"
echo
echo "  A) Easiest — from THIS machine:"
echo "     ssh-copy-id -i $PUB <user>@<remote-host>"
echo
echo "  B) Paste-and-run ON THE REMOTE server:"
echo "----------------------------------------------------------------------"
cat <<PASTE
mkdir -p ~/.ssh && chmod 700 ~/.ssh && \\
echo "$PUBKEY" >> ~/.ssh/authorized_keys && \\
chmod 600 ~/.ssh/authorized_keys && \\
echo "Key added."
PASTE
echo "----------------------------------------------------------------------"
echo
echo "  C) One-shot from here (pipes the key over SSH):"
echo "     cat $PUB | ssh <user>@<remote-host> 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'"
echo
echo "Then connect with:  ssh -i $KEY <user>@<remote-host>"
SCRIPT
chmod +x /usr/local/sbin/sshkey-gen
echo "Installed. Run:  sshkey-gen   (run as the user who will use the key, no sudo needed)"
EOF

sshkey-gen
