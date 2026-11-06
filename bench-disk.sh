#!/usr/bin/env bash
sudo bash <<'EOF'
command -v fio >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=180 update -qq && apt-get -o DPkg::Lock::Timeout=180 install -y -qq fio >/dev/null; }

cat > /usr/local/sbin/bench-disk <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# bench-disk -- the real speed of a disk, measured the way servers use it.
#
#   bench-disk              test the disk that holds /var/tmp
#   bench-disk /path        test the filesystem of that directory
#
# Four fio runs on a 1 GiB scratch file (direct I/O, so the page cache does not
# flatter the result), deleted at the end:
#   random 4K read  IOPS   -> databases, RADIUS, small files
#   random 4K write IOPS
#   sequential 1M read/write MB/s -> backups, video, big copies
#   fsync latency          -> how long one committed write takes (PostgreSQL feel)
# Needs about 1.2 GiB free. Your data is never touched.
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; R=$'\033[0m'
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
kv()    { printf '  %-24s %s\n' "$1" "$2"; }
DIR=${1:-/var/tmp}
[ -d "$DIR" ] || { echo "No such directory: $DIR"; exit 1; }
FREE=$(df -Pk "$DIR" | awk 'NR==2{print $4}')
[ "${FREE:-0}" -lt 1300000 ] && { echo "Need about 1.3 GiB free on $DIR (have $((FREE/1024)) MiB)."; exit 1; }
F="$DIR/.bench-disk.$$"; trap 'rm -f "$F"' EXIT

title "Disk"
SRC=$(df -P "$DIR" | awk 'NR==2{print $1}'); FS=$(df -PT "$DIR" | awk 'NR==2{print $2}')
DEV=$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1); [ -z "$DEV" ] && DEV=$(basename "$SRC")
ROT=$(cat /sys/block/"$DEV"/queue/rotational 2>/dev/null)
MODEL=$(cat /sys/block/"$DEV"/device/model 2>/dev/null | sed 's/ *$//')
kv "Tested path" "$DIR  ($FS on $SRC)"
kv "Device" "${DEV:-?} ${MODEL:+ ($MODEL)}"
kv "Kernel says" "$([ "$ROT" = 1 ] && echo 'spinning disk (HDD)' || echo 'solid state / virtual')"
kv "Free space" "$(df -Ph "$DIR" | awk 'NR==2{print $4" of "$2" ("$5" used)"}')"

ioengine=libaio; fio --enghelp 2>/dev/null | grep -q io_uring && ioengine=io_uring
run() { fio --name=t --filename="$F" --size=1G --direct=1 --ioengine=$ioengine --runtime=8 --time_based \
           --group_reporting --output-format=terse --terse-version=3 "$@" 2>/dev/null; }
echo; echo "  Preparing a 1 GiB scratch file..."
fio --name=prep --filename="$F" --size=1G --rw=write --bs=1M --direct=1 --ioengine=$ioengine >/dev/null 2>&1

title "Random 4K (8 s each, queue depth 32)"
RR=$(run --rw=randread  --bs=4k --iodepth=32 --numjobs=1 | awk -F';' '{printf "%d", $8}')
RW=$(run --rw=randwrite --bs=4k --iodepth=32 --numjobs=1 | awk -F';' '{printf "%d", $49}')
kv "Read IOPS" "${B}${RR}${R}"
kv "Write IOPS" "${B}${RW}${R}"

title "Sequential 1M (8 s each)"
SR=$(run --rw=read  --bs=1M --iodepth=8 | awk -F';' '{printf "%.0f", $7/1024}')
SW=$(run --rw=write --bs=1M --iodepth=8 | awk -F';' '{printf "%.0f", $48/1024}')
kv "Read" "${B}${SR} MB/s${R}"
kv "Write" "${B}${SW} MB/s${R}"

title "Committed write latency (fsync after every 4K write, like a database)"
FS_OUT=$(fio --name=sync --filename="$F" --size=64M --rw=write --bs=4k --fsync=1 --ioengine=sync \
              --runtime=8 --time_based --output-format=terse --terse-version=3 2>/dev/null)
SYNC_IOPS=$(awk -F';' '{printf "%d", $49}' <<<"$FS_OUT")
SYNC_LAT=$(awk -v i="${SYNC_IOPS:-0}" 'BEGIN{ if (i>0) printf "%.2f", 1000/i; else print "?" }')
kv "Commits per second" "${B}${SYNC_IOPS}${R}"
kv "Average per commit" "${SYNC_LAT} ms"

title "Verdict"
awk -v r="${RR:-0}" -v s="${SR:-0}" -v c="${SYNC_IOPS:-0}" -v G="$G" -v Y="$Y" -v RD="$RD" -v R="$R" 'BEGIN{
  if (r>=100000) cls = G "NVMe class" R;
  else if (r>=20000) cls = G "SSD class" R;
  else if (r>=3000) cls = Y "network / shared SSD class" R;
  else cls = RD "HDD or heavily throttled storage" R;
  print "  Random reads: " cls;
  if (c < 300) print "  " RD "Slow commits:" R " databases (PostgreSQL, RADIUS accounting) will feel it";
  else if (c < 1500) print "  " Y "Commits OK" R " for small and medium databases";
  else print "  " G "Fast commits" R ": databases will be happy";
  print "  Reference: NVMe 200k+ IOPS / 2000+ MB/s, SATA SSD ~50-90k / 500 MB/s, HDD ~150 / 150 MB/s."
}'
SCRIPT
chmod +x /usr/local/sbin/bench-disk
echo "Installed. Run:  bench-disk   (or: bench-disk /path/on/other/disk)"
EOF

bench-disk
