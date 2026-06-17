#!/usr/bin/env bash
sudo bash <<'EOF'
echo "=== 1/4: Updating package lists ==="
apt-get update

echo "=== 2/4: Upgrading installed packages ==="
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade

echo "=== 3/4: Removing obsolete packages ==="
apt-get -y autoremove --purge
apt-get -y autoclean

echo "=== 4/4: Upgrading Ubuntu release ==="
command -v do-release-upgrade >/dev/null || apt-get install -y ubuntu-release-upgrader-core
# allow LTS-to-LTS or normal depending on what's available
do-release-upgrade -f DistUpgradeViewNonInteractive

echo
echo "Done. A reboot is recommended:  sudo reboot"
EOF
