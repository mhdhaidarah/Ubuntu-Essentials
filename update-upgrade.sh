#!/usr/bin/env bash
sudo bash <<'EOF'
echo "=== 1/5: Updating package lists ==="
apt-get update

echo "=== 2/5: Upgrading installed packages ==="
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade

echo "=== 3/5: Removing obsolete packages ==="
apt-get -y autoremove --purge
apt-get -y autoclean

echo "=== 4/5: Enabling automatic security updates ==="
apt-get install -y unattended-upgrades

# The usual recipe is `dpkg-reconfigure -plow unattended-upgrades`, which opens
# a debconf dialog. Everything else here runs unattended, so a prompt would hang
# the script when it is piped or run from cron — and an unanswered dialog leaves
# automatic updates OFF, which is the one outcome this step exists to prevent.
# Setting the same debconf answer directly gets the identical result without
# asking, and `-f noninteractive` then writes 20auto-upgrades.
echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' \
  | debconf-set-selections
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive -plow unattended-upgrades
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

echo "--- automatic updates now configured as: ---"
cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || echo "  (20auto-upgrades not written)"
systemctl is-enabled unattended-upgrades 2>/dev/null | sed 's/^/  service: /'

echo "=== 5/5: Upgrading Ubuntu release ==="
command -v do-release-upgrade >/dev/null || apt-get install -y ubuntu-release-upgrader-core
# allow LTS-to-LTS or normal depending on what's available
do-release-upgrade -f DistUpgradeViewNonInteractive

echo
echo "Done. A reboot is recommended:  sudo reboot"
EOF
