#!/usr/bin/env bash
sudo bash <<'EOF'
command -v lsof >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=180 update -qq && apt-get -o DPkg::Lock::Timeout=180 install -y -qq lsof psmisc >/dev/null; }

cat > /usr/local/sbin/proc-tools <<'SCRIPT'
#!/bin/bash
# ---------------------------------------------------------------------------
# proc-tools -- see and handle processes without remembering ten commands.
#
#   proc-tools          menu
#   proc-tools 1..10    one view directly
#
# Views (read-only): top CPU, top memory, tree, find by name, who owns a port,
# open files/sockets of a process, zombies, CPU/memory per service.
# Actions (ask before doing anything): stop a process (polite, then forced),
# change its priority, cap a service's CPU.
# ---------------------------------------------------------------------------
B=$'\033[1m'; CY=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; RD=$'\033[1;31m'; DIM=$'\033[2m'; R=$'\033[0m'
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }
title() { echo; printf '%s== %s%s\n' "$CY" "$1" "$R"; }
yes_no() { read -rp "  $1 [y/N] " a; [ "${a,,}" = y ]; }
hdr() { printf '  %s%7s %-10s %6s %6s %9s %10s  %s%s\n' "$DIM" PID USER CPU% MEM% RSS ELAPSED COMMAND "$R"; }
row() { awk '{rss=$5; u="K"; if(rss>=1048576){rss/=1048576;u="G"} else if(rss>=1024){rss/=1024;u="M"}
              cmd=""; for(i=7;i<=NF;i++) cmd=cmd" "$i; printf "  %7s %-10s %6s %6s %8.1f%s %10s %s\n", $1, substr($2,1,10), $3, $4, rss, u, $6, substr(cmd,1,70)}'; }

v_cpu() { title "Top CPU (averaged since each process started; live view: 'top' or 'htop')"; hdr; ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-pcpu --no-headers | head -15 | row; }
v_mem() { title "Top memory"; hdr; ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-rss --no-headers | head -15 | row; }
v_tree() { title "Process tree"; pstree -apul 2>/dev/null | head -80 | sed 's/^/  /'; }
v_find() { read -rp "  Name or part of the command line: " q; [ -z "$q" ] && return
  title "Processes matching '$q'"; hdr; ps -eo pid,user,pcpu,pmem,rss,etime,args --no-headers | grep -i -- "$q" | grep -v -e "grep -i" -e proc-tools | row; }
v_port() { read -rp "  Port number: " p; [[ "$p" =~ ^[0-9]+$ ]] || return
  title "Who uses port $p"; ss -Htulpn "sport = :$p" 2>/dev/null | sed 's/^/  /'
  ss -Htnp "( sport = :$p or dport = :$p )" state established 2>/dev/null | head -20 | sed 's/^/  /'; }
v_files() { read -rp "  PID: " p; [[ "$p" =~ ^[0-9]+$ ]] || return
  title "Process $p: $(ps -o comm= -p "$p")"
  printf '  %-18s %s\n' "Started" "$(ps -o lstart= -p "$p")" "Command" "$(tr '\0' ' ' < /proc/$p/cmdline | cut -c1-100)" \
    "Threads" "$(ls /proc/$p/task 2>/dev/null | wc -l)" "Open files" "$(ls /proc/$p/fd 2>/dev/null | wc -l) (limit $(awk '/open files/{print $4}' /proc/$p/limits))" \
    "Service" "$(cat /proc/$p/cgroup 2>/dev/null | awk -F/ '{print $NF}' | head -1)"
  echo; echo "  Network sockets:"; lsof -nP -a -p "$p" -i 2>/dev/null | tail -n +2 | head -15 | awk '{printf "    %-6s %s %s\n", $5, $9, $10}'
  echo "  Files (first 15):"; lsof -nP -p "$p" 2>/dev/null | awk '$5=="REG"{print "    "$9}' | sort -u | head -15; }
v_zombie() { title "Zombie processes (finished but not collected by their parent)"
  z=$(ps -eo pid,ppid,stat,comm --no-headers | awk '$3 ~ /Z/')
  if [ -z "$z" ]; then echo "  ${G}None.${R}"; else echo "$z" | while read -r pid ppid st c; do
    echo "  zombie $pid ($c)  parent $ppid ($(ps -o comm= -p "$ppid"))"; done
    echo "  ${DIM}Zombies cost nothing but a PID. Restarting the PARENT clears them.${R}"; fi; }
v_services() { title "CPU and memory per service (one 3 s sample)"
  printf '  %s%-34s %6s %10s %8s%s\n' "$DIM" "service" "tasks" "CPU%" "memory" "$R"
  systemd-cgtop -b -n 2 -d 3 --order=cpu --raw 2>/dev/null | awk '$1 ~ /\.service$/ {n=split($1,a,"/"); last[a[n]]=$0} END{for(k in last) print last[k]}' \
    | sort -k3 -nr | head -15 | awk '{n=split($1,a,"/"); m=$4; u="B"; if(m>=1073741824){m/=1073741824;u="G"} else if(m>=1048576){m/=1048576;u="M"} else if(m>=1024){m/=1024;u="K"}
      printf "  %-34s %6s %10s %7.1f%s\n", a[n], $2, ($3=="-"?"-":sprintf("%.1f",$3)), m, u}'; }
a_kill() { read -rp "  PID to stop: " p; [[ "$p" =~ ^[0-9]+$ ]] || return
  c=$(ps -o comm= -p "$p") || { echo "  No such process."; return; }
  [ "$p" -le 1 ] && { echo "  Refused: PID 1 is the system itself."; return; }
  yes_no "Stop $p ($c)? A polite TERM first, KILL after 5 s if it is still there." || return
  kill -TERM "$p"; for i in 1 2 3 4 5; do sleep 1; kill -0 "$p" 2>/dev/null || { echo "  ${G}Stopped.${R}"; return; }; done
  yes_no "Still running. Force it (KILL)?" && kill -KILL "$p" && echo "  ${Y}Killed.${R}"; }
a_nice() { read -rp "  PID: " p; [[ "$p" =~ ^[0-9]+$ ]] || return
  read -rp "  New priority -20 (highest) .. 19 (lowest), now $(ps -o ni= -p "$p" | tr -d ' '): " n
  [[ "$n" =~ ^-?[0-9]+$ ]] && renice -n "$n" -p "$p" | sed 's/^/  /'; }
a_cap() { read -rp "  Service name (e.g. nginx, samm-api): " s; [ -z "$s" ] && return
  read -rp "  CPU cap in % of ONE core (e.g. 50; 200 = two cores; empty = remove the cap): " q
  if [ -z "$q" ]; then systemctl set-property "$s" CPUQuota= && echo "  Cap removed from $s."
  elif [[ "$q" =~ ^[0-9]+$ ]]; then yes_no "Cap $s at ${q}% CPU (kept across reboots)?" && systemctl set-property "$s" CPUQuota="${q}%" && echo "  ${G}$s capped at ${q}%.${R}"; fi; }
pick() { case "$1" in 1) v_cpu;; 2) v_mem;; 3) v_tree;; 4) v_find;; 5) v_port;; 6) v_files;; 7) v_zombie;; 8) v_services;;
                     9) a_kill;; 10) a_nice;; 11) a_cap;; *) return 1;; esac; }
[ -n "${1:-}" ] && { pick "$1"; exit; }
while true; do
  echo; echo "${B}proc-tools${R}  ${DIM}load $(cut -d' ' -f1-3 /proc/loadavg), $(ps -e --no-headers | wc -l) processes${R}"
  echo "  1) top CPU           5) who uses a port          9)  stop a process"
  echo "  2) top memory        6) details + open files     10) change priority"
  echo "  3) process tree      7) zombies                  11) cap a service's CPU"
  echo "  4) find by name      8) usage per service        Enter) quit"
  read -rp "Choice: " C; [ -z "$C" ] && exit 0; pick "$C" || echo "  Unknown choice."
done
SCRIPT
chmod +x /usr/local/sbin/proc-tools
echo "Installed. Run:  sudo proc-tools"
EOF

sudo proc-tools
