#!/usr/bin/env bash
sudo bash <<'EOF'
# Install Ookla speedtest CLI if missing (falls back to speedtest-cli if Ookla repo unavailable)
if ! command -v speedtest >/dev/null 2>&1; then
  if ! command -v speedtest-cli >/dev/null 2>&1; then
    apt-get update && apt-get install -y speedtest-cli
  fi
fi

cat > /usr/local/sbin/speedcheck <<'SCRIPT'
#!/bin/bash
# One-shot speed test. Optional arg: interface name to bind the test to a specific uplink.
IFACE="$1"

echo "Running speed test...${IFACE:+ (via $IFACE)}"
echo

if command -v speedtest >/dev/null 2>&1; then
  # Ookla official CLI
  if [ -n "$IFACE" ]; then
    SRCIP=$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
    speedtest --accept-license --accept-gdpr ${SRCIP:+--ip "$SRCIP"}
  else
    speedtest --accept-license --accept-gdpr
  fi
elif command -v speedtest-cli >/dev/null 2>&1; then
  # Python speedtest-cli
  if [ -n "$IFACE" ]; then
    SRCIP=$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
    speedtest-cli ${SRCIP:+--source "$SRCIP"}
  else
    speedtest-cli
  fi
else
  echo "No speedtest tool found."; exit 1
fi
SCRIPT
chmod +x /usr/local/sbin/speedcheck
echo "Installed. Run:  speedcheck   (or: speedcheck ppp0  to test a specific uplink)"
EOF

speedtest
