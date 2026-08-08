#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/net-diag <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# ---------------------------------------------------------------------------
# net-diag - interactive network diagnostics.
#
# Everything in here is read-only: it looks, measures and reports, and the only
# thing it ever changes on the box is installing a diagnostic package (mtr,
# traceroute, dig) after asking. That is deliberate - this tool gets run on
# customer routers and uplink boxes in the middle of an outage, where the last
# thing anyone needs is a wizard "helpfully" rewriting the network config.
# ---------------------------------------------------------------------------

# ip, ss and ping live in /usr/sbin or /sbin on some releases. A sudo with a
# trimmed secure_path, or an invocation from cron/systemd, can leave those out
# of PATH entirely - and then every probe below would "succeed" at finding
# nothing and we would confidently report a box with no network at all.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

# We parse English keywords out of ping, dig and ip ("packet loss", "time=",
# "Connection refused"). On a box with a localised locale those strings change
# and every match silently returns nothing, which reads as "total failure".
export LC_ALL=C

have() { command -v "$1" >/dev/null 2>&1; }

rule() { printf '%s\n' "---------------------------------------------------------------------------"; }

pause() {
  echo
  # read returns non-zero at EOF (someone piped input, or stdin is closed), and
  # under `set -e` that would kill the whole tool instead of just moving on.
  read -rp "Press Enter to return to the menu... " _ || true
}

is_num() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# Print the first IPv4 for a name (or the name itself if it already is an IP).
# getent exits 2 when the name does not resolve, hence the `|| true`; callers
# must test the returned string, because a function that prints nothing still
# exits 0 and `$(resolve4 x) || echo fallback` would never fire.
resolve4() {
  local r=""
  case "$1" in
    '') return 0 ;;
    *[!0-9.]*) : ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  r=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}') || true
  printf '%s' "$r"
}

# A target we are going to hand to /dev/tcp or ping must contain nothing but
# address characters - this is the guard that keeps a hostile or fat-fingered
# "host" string from turning into shell, and it also rejects the HTML error
# page a captive portal returns instead of an IP.
is_ipish() {
  case "$1" in
    ''|*[!0-9a-fA-F.:]*) return 1 ;;
  esac
  return 0
}

default_dev() {
  local d=""
  d=$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}') || true
  printf '%s' "$d"
}

fw_line() {
  local out="" u="" f=""
  if have ufw; then
    u=$(ufw status 2>/dev/null | awk 'NR==1{print $2}') || true
    out="ufw ${u:-unknown}"
  else
    out="ufw absent"
  fi
  if have firewall-cmd; then
    # firewall-cmd --state prints "not running" AND exits 252 when the daemon is
    # down: capture with stderr discarded and judge the variable, never the
    # exit status, or we get both the word and a spurious failure.
    f=$(firewall-cmd --state 2>/dev/null) || true
    out="$out | firewalld ${f:-not running}"
  else
    out="$out | firewalld absent"
  fi
  printf '%s' "$out"
}

# One resolver IP per line: what resolv.conf points at, plus the real upstreams
# behind the systemd-resolved stub (127.0.0.53 answering is useless information
# if the servers it forwards to are dead).
list_resolvers() {
  {
    awk '/^[[:space:]]*nameserver/{print $2}' /etc/resolv.conf 2>/dev/null || true
    if have resolvectl; then
      resolvectl status 2>/dev/null | grep -E 'DNS Server' \
        | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' || true
    fi
  } | awk 'NF && !seen[$0]++'
}

# Public address as the rest of the world sees it. Several endpoints are tried
# because any single one of them can be blocked, rate-limited or down, and a
# short --max-time keeps a black-holed uplink from freezing the menu.
pub_ip() {
  local fam="$1" ip="" u=""
  # Nothing to try without an HTTP client, and looping three times to discover
  # that again would just waste the operator's time.
  if ! have curl && ! have wget; then
    return 0
  fi
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    if have curl; then
      ip=$(curl "$fam" -fsS --max-time 5 "$u" 2>/dev/null) || ip=""
    else
      # wget takes -4/-6 too; without passing the family through, an IPv6 probe
      # would happily answer over IPv4 and report the wrong address.
      ip=$(wget "$fam" -qO- --timeout=5 "$u" 2>/dev/null) || ip=""
    fi
    ip=$(printf '%s' "$ip" | tr -d '[:space:]') || true
    # A captive portal or an ISP error page returns 200 with HTML in it. Only
    # something that is literally an address may be printed as one.
    if [ -n "$ip" ] && [ "${#ip}" -le 45 ] && is_ipish "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
    ip=""
  done
  return 0
}

# ensure_pkg <command> <package>... - offer to apt-get install until the
# command appears. Returns 1 if the operator declines or nothing works, so the
# caller can bail out cleanly instead of running a tool that is not there.
ensure_pkg() {
  local cmd="$1"; shift
  local a="" p=""
  if have "$cmd"; then
    return 0
  fi
  if ! have apt-get; then
    echo "'$cmd' is missing and this box has no apt-get - install it by hand."
    return 1
  fi
  echo "'$cmd' is not installed on this box."
  read -rp "Install it now with apt-get? [y/N]: " a || true
  case "$a" in
    y|Y|yes|YES) : ;;
    *) return 1 ;;
  esac
  # A broken or unreachable third-party repo makes `apt-get update` fail; that
  # must not stop the install, because the package we want may well be cached
  # or available from the main archive anyway.
  #
  # Lock::Timeout matters more than it looks: unattended-upgrades holds the
  # dpkg lock for minutes, and without a timeout apt-get waits for it forever
  # with no output, which looks exactly like the tool having hung.
  apt-get -o DPkg::Lock::Timeout=60 update -qq || true
  for p in "$@"; do
    apt-get -o DPkg::Lock::Timeout=60 install -y "$p" >/dev/null 2>&1 || true
    if have "$cmd"; then
      echo "Installed $p."
      return 0
    fi
  done
  echo "Could not install $cmd (tried: $*)."
  return 1
}

# ---------------------------------------------------------------------------
# 1) Overview
# ---------------------------------------------------------------------------
do_overview() {
  local i state mtu v4 v6 dst ip out dev src via r p4 p6 has6
  rule
  echo "INTERFACES"
  printf "  %-14s %-8s %-6s %-22s %s\n" "NAME" "STATE" "MTU" "IPv4" "IPv6 (global)"
  local ifs_list=()
  mapfile -t ifs_list < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1)
  for i in "${ifs_list[@]}"; do
    state=$(cat "/sys/class/net/$i/operstate" 2>/dev/null) || true
    mtu=$(cat "/sys/class/net/$i/mtu" 2>/dev/null) || true
    v4=$(ip -4 -o addr show dev "$i" 2>/dev/null | awk '{print $4}' | paste -sd, -) || true
    v6=$(ip -6 -o addr show dev "$i" scope global 2>/dev/null | awk '{print $4}' | paste -sd, -) || true
    printf "  %-14s %-8s %-6s %-22s %s\n" "$i" "${state:-?}" "${mtu:-?}" "${v4:-none}" "${v6:-none}"
  done

  echo
  echo "DEFAULT ROUTES"
  out=$(ip -4 route show default 2>/dev/null) || true
  printf "  v4: %s\n" "${out:-none}"
  out=$(ip -6 route show default 2>/dev/null | head -3) || true
  printf "  v6: %s\n" "${out:-none}"

  echo
  echo "RESOLVERS"
  local res=()
  mapfile -t res < <(list_resolvers)
  if [ "${#res[@]}" -eq 0 ]; then
    echo "  none configured - name resolution cannot work"
  else
    for r in "${res[@]}"; do
      case "$r" in
        127.0.0.53) printf "  %-24s (systemd-resolved stub; the real servers are listed too)\n" "$r" ;;
        *) printf "  %s\n" "$r" ;;
      esac
    done
  fi

  echo
  printf "FIREWALL\n  %s\n" "$(fw_line)"

  echo
  echo "ROUTE DECISION"
  read -rp "  Destination to test the routing decision for [8.8.8.8]: " dst || true
  dst="${dst:-8.8.8.8}"
  ip=$(resolve4 "$dst")
  if [ -z "$ip" ]; then
    echo "  '$dst' does not resolve - showing nothing; fix DNS first (menu 5)."
  else
    # `ip route get` exits non-zero for unreachable destinations and prints the
    # reason on stderr; keep the message and show it instead of dying.
    out=$(ip route get "$ip" 2>&1) || true
    printf "  %s\n" "$out"
    dev=$(printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}') || true
    src=$(printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}') || true
    via=$(printf '%s\n' "$out" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1); exit}') || true
    if [ -n "$dev" ]; then
      # No "via" in the answer means the destination is on a directly attached
      # subnet - say so rather than printing an empty next hop.
      if [ -n "$via" ]; then
        printf "  -> leaves by %s, source %s, next hop %s\n" "$dev" "${src:-?}" "$via"
      else
        printf "  -> leaves by %s, source %s, directly attached (no gateway)\n" "$dev" "${src:-?}"
      fi
    fi
  fi

  echo
  echo "PUBLIC ADDRESS (as seen from outside)"
  p4=$(pub_ip -4)
  printf "  IPv4: %s\n" "${p4:-unavailable (no outbound HTTPS, or curl/wget missing)}"
  has6=$(ip -6 -o addr show scope global 2>/dev/null | head -1) || true
  if [ -n "$has6" ]; then
    p6=$(pub_ip -6)
    printf "  IPv6: %s\n" "${p6:-unavailable (global v6 address exists but nothing answered)}"
  else
    printf "  IPv6: no global address on this box\n"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 2) Ping test
# ---------------------------------------------------------------------------
do_ping() {
  local target count ip out loss stats
  read -rp "Target [8.8.8.8]: " target || true
  target="${target:-8.8.8.8}"
  read -rp "Packets [5]: " count || true
  count="${count:-5}"
  if ! is_num "$count" || [ "$count" -lt 1 ] || [ "$count" -gt 1000 ]; then
    echo "Packet count must be a number between 1 and 1000."
    return 0
  fi
  ip=$(resolve4 "$target")
  if [ -z "$ip" ]; then
    echo "'$target' does not resolve - check DNS with menu 5."
    return 0
  fi
  echo
  echo "Pinging $target ($ip) x$count ..."
  # ping exits 1 on 100% loss and 2 on other errors, which is exactly the case
  # we are here to diagnose - capture it and read the summary, never let the
  # exit status end the run.
  out=$(ping -n -c "$count" -W 2 "$ip" 2>&1) || true
  loss=$(printf '%s\n' "$out" | grep -E 'packet loss' | head -1) || true
  stats=$(printf '%s\n' "$out" | grep -E '^(rtt|round-trip)' | head -1) || true
  rule
  printf '%s\n' "$out" | sed 's/^/  /'
  rule
  if [ -z "$loss" ]; then
    echo "  No summary line - the target never answered and ping gave up early."
    echo "  Check the route decision (menu 1) and whether ICMP is filtered."
  else
    printf "  %s\n" "$loss"
    printf "  %s\n" "${stats:-no timing available (nothing came back)}"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 3) Continuous quality - one probe per second for N seconds
# ---------------------------------------------------------------------------
do_quality() {
  local target secs ip i rc out rtt t0 t1 el rem sent=0 lost=0 streak=0 worst=0
  local rtts=()
  read -rp "Target [8.8.8.8]: " target || true
  target="${target:-8.8.8.8}"
  read -rp "Duration in seconds [60]: " secs || true
  secs="${secs:-60}"
  if ! is_num "$secs" || [ "$secs" -lt 5 ] || [ "$secs" -gt 3600 ]; then
    echo "Duration must be a number between 5 and 3600 seconds."
    return 0
  fi
  ip=$(resolve4 "$target")
  if [ -z "$ip" ]; then
    echo "'$target' does not resolve - check DNS with menu 5."
    return 0
  fi

  echo
  echo "Sampling $target ($ip) once a second for ${secs}s.  '.' = reply, '!' = no reply"
  echo "Ctrl-C stops early and still prints the result."
  echo
  # A flapping uplink is often obvious after 20 seconds of a 300 second run, so
  # trap INT, break the loop and report what we have. Without this the operator
  # would abort and lose every sample collected so far.
  local STOP=0
  trap 'STOP=1' INT
  i=0
  while [ "$i" -lt "$secs" ]; do
    if [ "$STOP" -eq 1 ]; then
      echo
      echo "(stopped early after $sent samples)"
      break
    fi
    t0=$(date +%s%N)
    rc=0
    out=$(ping -n -c 1 -W 1 "$ip" 2>/dev/null) || rc=$?
    sent=$((sent + 1))
    rtt=""
    if [ "$rc" -eq 0 ]; then
      rtt=$(printf '%s\n' "$out" | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2) || true
    fi
    if [ -n "$rtt" ]; then
      rtts+=("$rtt")
      streak=0
      printf '.'
    else
      lost=$((lost + 1))
      streak=$((streak + 1))
      if [ "$streak" -gt "$worst" ]; then
        worst="$streak"
      fi
      printf '!'
    fi
    i=$((i + 1))
    if [ $((sent % 60)) -eq 0 ]; then
      printf '  %4ds\n' "$sent"
    fi
    # Pace to a real one-second interval: a reply takes a few ms but a timeout
    # already burned a whole second, so sleep only the remainder or a lossy run
    # would take twice as long as the operator asked for.
    #
    # The `|| true` is what makes Ctrl-C work at all: a trapped SIGINT kills
    # sleep, sleep returns 130, and under `set -e` that non-zero status would
    # tear the whole tool down and throw away every sample - the exact loss the
    # trap above exists to prevent.
    t1=$(date +%s%N)
    el=$(( (t1 - t0) / 1000000 ))
    rem=$(( 1000 - el ))
    if [ "$rem" -gt 0 ] && [ "$i" -lt "$secs" ] && [ "$STOP" -eq 0 ]; then
      sleep "$(awk -v m="$rem" 'BEGIN{printf "%.3f", m/1000}')" || true
    fi
  done
  trap - INT
  echo
  echo

  rule
  local pct
  pct=$(awk -v l="$lost" -v s="$sent" 'BEGIN{ if(s>0) printf "%.1f", l*100/s; else print "0.0" }')
  printf "  sent %d, lost %d  (%s%% loss)\n" "$sent" "$lost" "$pct"
  if [ "$worst" -gt 0 ]; then
    printf "  longest unbroken outage: %ds\n" "$worst"
  fi
  if [ "${#rtts[@]}" -gt 0 ]; then
    printf '%s\n' "${rtts[@]}" | awk '
      NR==1 { min=max=sum=$1; prev=$1; n=1; next }
      { n++; sum+=$1; if($1<min) min=$1; if($1>max) max=$1;
        d=$1-prev; if(d<0) d=-d; jsum+=d; jn++; prev=$1 }
      END {
        printf "  min/avg/max: %.1f / %.1f / %.1f ms\n", min, sum/n, max
        if (jn>0) printf "  jitter (mean change between consecutive replies): %.1f ms\n", jsum/jn
      }'
  fi
  rule
  echo "  Rule of thumb: VoIP wants <1% loss and <30 ms jitter. Repeated '!' in"
  echo "  bursts is a flapping uplink; scattered single '!' is usually ICMP rate"
  echo "  limiting at the far end - repeat against a different target to confirm."
  return 0
}

# ---------------------------------------------------------------------------
# 4) mtr / traceroute
# ---------------------------------------------------------------------------
do_trace() {
  local target ip cycles ans
  read -rp "Target [8.8.8.8]: " target || true
  target="${target:-8.8.8.8}"
  ip=$(resolve4 "$target")
  if [ -z "$ip" ]; then
    echo "'$target' does not resolve - check DNS with menu 5."
    return 0
  fi
  read -rp "Cycles per hop [10]: " cycles || true
  cycles="${cycles:-10}"
  if ! is_num "$cycles" || [ "$cycles" -lt 1 ] || [ "$cycles" -gt 200 ]; then
    echo "Cycles must be a number between 1 and 200."
    return 0
  fi

  if have mtr || ensure_pkg mtr mtr-tiny mtr; then
    read -rp "Resolve hop names? (slow, and pointless with broken DNS) [y/N]: " ans || true
    echo
    case "$ans" in
      y|Y|yes|YES) mtr --report --report-wide --report-cycles "$cycles" "$ip" || true ;;
      *) mtr --report --report-wide --report-cycles "$cycles" -n "$ip" || true ;;
    esac
    echo
    echo "  Read the Loss% column from the BOTTOM up: loss that appears at one hop"
    echo "  and disappears again is that router de-prioritising ICMP to itself, not"
    echo "  a fault. Only loss that continues to the last hop is real."
    return 0
  fi

  echo "Falling back to traceroute."
  if have traceroute || ensure_pkg traceroute traceroute; then
    traceroute -n -w 2 -q 2 "$ip" || true
  elif have tracepath; then
    tracepath -n "$ip" || true
  else
    echo "Neither mtr nor traceroute nor tracepath is available."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 5) DNS check
# ---------------------------------------------------------------------------
do_dns() {
  local name entry srv tag rc out ans t0 t1 ms ok=0 bad=0
  local failed=()
  read -rp "Name to resolve [google.com]: " name || true
  name="${name:-google.com}"
  if ! have dig; then
    # dnsutils is the 20.04 name, bind9-dnsutils the 22.04+ one; try both.
    if ! ensure_pkg dig bind9-dnsutils dnsutils; then
      echo "Cannot test resolvers individually without dig."
      return 0
    fi
  fi

  # Configured resolvers first, then two public ones as a control. If the
  # configured server fails while the controls answer, the fault is the
  # resolver; if everything fails, the fault is the link or a UDP/53 block.
  local list=()
  mapfile -t list < <( { list_resolvers | sed 's/$/ configured/'
                         echo "8.8.8.8 control (Google)"
                         echo "1.1.1.1 control (Cloudflare)"; } | awk '!seen[$1]++' )

  echo
  printf "  %-20s %-22s %-8s %-8s %s\n" "RESOLVER" "SOURCE" "RESULT" "TIME" "ANSWER"
  rule
  for entry in "${list[@]}"; do
    srv=$(printf '%s' "$entry" | awk '{print $1}')
    tag=$(printf '%s' "$entry" | cut -d' ' -f2-)
    t0=$(date +%s%N)
    rc=0
    out=$(dig +tries=1 +time=2 +short "@$srv" "$name" A 2>/dev/null) || rc=$?
    t1=$(date +%s%N)
    ms=$(( (t1 - t0) / 1000000 ))
    ans=$(printf '%s\n' "$out" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' | head -1) || true
    if [ "$rc" -ne 0 ]; then
      printf "  %-20s %-22s %-8s %-8s %s\n" "$srv" "$tag" "FAIL" "${ms}ms" "no reply (timeout/unreachable)"
      failed+=("$srv")
      bad=$((bad + 1))
    elif [ -z "$ans" ]; then
      printf "  %-20s %-22s %-8s %-8s %s\n" "$srv" "$tag" "EMPTY" "${ms}ms" "answered but gave no A record"
      failed+=("$srv")
      bad=$((bad + 1))
    else
      printf "  %-20s %-22s %-8s %-8s %s\n" "$srv" "$tag" "OK" "${ms}ms" "$ans"
      ok=$((ok + 1))
      if [ "$ms" -gt 300 ]; then
        printf "  %-20s %s\n" "" "^ slow: over 300 ms means every page load pays for it"
      fi
    fi
  done
  rule
  if [ "$ok" -eq 0 ]; then
    echo "  NO resolver answered. That is not a DNS server fault - either this box"
    echo "  has no route out (menu 1) or UDP/53 is blocked upstream (menu 7, port 53)."
  elif [ "$bad" -gt 0 ]; then
    printf "  Broken resolver(s): %s\n" "${failed[*]}"
    echo "  Others answered over the same link, so the link is fine and those"
    echo "  servers are the problem - remove them from the interface config."
  else
    echo "  Every resolver answered."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 6) MTU discovery
# ---------------------------------------------------------------------------
# One do-not-fragment probe. Two attempts, because a single dropped packet in a
# binary search sends the whole search off in the wrong direction and yields a
# confidently wrong MTU.
mtu_probe() {
  local pay="$1" ip="$2"
  if ping -n -M "do" -s "$pay" -c 1 -W 2 "$ip" >/dev/null 2>&1; then
    return 0
  fi
  if ping -n -M "do" -s "$pay" -c 1 -W 2 "$ip" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

do_mtu() {
  local target ip dev ifmtu lo hi mid pmtu
  read -rp "Target to probe the path to [8.8.8.8]: " target || true
  target="${target:-8.8.8.8}"
  ip=$(resolve4 "$target")
  if [ -z "$ip" ] || ! is_ipish "$ip"; then
    echo "'$target' does not resolve to a usable address."
    return 0
  fi
  dev=$(ip route get "$ip" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}') || true
  ifmtu=""
  if [ -n "$dev" ]; then
    ifmtu=$(cat "/sys/class/net/$dev/mtu" 2>/dev/null) || true
  fi
  # Anything non-numeric out of sysfs (or nothing at all, when the route lookup
  # failed) would make the arithmetic below produce nonsense, so fall back to
  # the Ethernet default rather than computing on a bad number.
  if ! is_num "$ifmtu"; then
    ifmtu=1500
  fi

  # 28 bytes = 20 IPv4 header + 8 ICMP header, so payload + 28 = the MTU.
  lo=64
  hi=$((ifmtu - 28))
  # A tunnel or a deliberately tiny MTU can leave no room between the smallest
  # probe and the interface itself. Without this the search loop never runs and
  # we would print a fabricated "path MTU: 92" that no operator could act on.
  if [ "$hi" -le "$lo" ]; then
    echo
    echo "  Interface ${dev:-?} has an MTU of $ifmtu - too small to probe"
    echo "  meaningfully (the search needs room above a 64-byte payload)."
    return 0
  fi

  echo
  echo "Outgoing interface: ${dev:-unknown}  (MTU $ifmtu)"
  # The whole search is meaningless if the target simply does not answer ICMP:
  # every probe would "fail" and we would report an MTU of nothing. Prove a
  # small packet works before believing anything about a large one.
  echo "Checking that plain ICMP works at all..."
  if ! mtu_probe 64 "$ip"; then
    echo
    echo "  $ip does not answer a 64-byte ping, so probe results would be noise."
    echo "  Pick a target that replies to ICMP (8.8.8.8 and 1.1.1.1 both do)."
    return 0
  fi

  echo "Searching for the largest payload that survives with DF set..."
  if mtu_probe "$hi" "$ip"; then
    pmtu="$ifmtu"
    echo
    printf "  Path MTU to %s: %d bytes - the full interface MTU passes.\n" "$target" "$pmtu"
    echo "  Nothing along the path is shrinking your packets."
    return 0
  fi
  while [ $((hi - lo)) -gt 1 ]; do
    mid=$(( (lo + hi) / 2 ))
    if mtu_probe "$mid" "$ip"; then
      lo="$mid"
    else
      hi="$mid"
    fi
    printf '.'
  done
  echo
  pmtu=$((lo + 28))
  echo
  rule
  printf "  largest payload that passed : %d bytes\n" "$lo"
  printf "  path MTU to %-15s : %d bytes\n" "$target" "$pmtu"
  printf "  interface MTU on %-10s : %d bytes\n" "${dev:-?}" "$ifmtu"
  rule
  echo "  Something on the path is smaller than this interface. Usual suspects:"
  echo "    1492  PPPoE          1476  GRE/IPIP       1420  WireGuard"
  echo "    1400  IPsec (approx) 1450  common VPS/tunnel overlay"
  echo "  Symptom of ignoring it: small packets (ping, DNS, SSH login) work fine"
  echo "  while big transfers and some HTTPS sites hang forever. Fix it by setting"
  echo "  the interface MTU to $pmtu, or by clamping TCP MSS to $((pmtu - 40))."
  echo "  Caveat: some routers drop large ICMP but forward large TCP happily, so"
  echo "  confirm with a real transfer before changing a working config."
  return 0
}

# ---------------------------------------------------------------------------
# 7) Port reachability
# ---------------------------------------------------------------------------
do_port() {
  local host port ip t0 t1 ms rc err loopback_only=0
  read -rp "Host to reach: " host || true
  if [ -z "$host" ]; then
    echo "No host given."
    return 0
  fi
  read -rp "TCP port: " port || true
  if ! is_num "$port" || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Port must be a number between 1 and 65535."
    return 0
  fi
  ip=$(resolve4 "$host")
  if [ -z "$ip" ]; then
    echo "'$host' does not resolve - check DNS with menu 5."
    return 0
  fi
  # Belt and braces: the address is about to be used to build a /dev/tcp path,
  # so refuse anything that is not purely an address.
  if ! is_ipish "$ip"; then
    echo "Refusing to test '$ip' - that is not a plain address."
    return 0
  fi

  echo
  echo "LOCAL LISTENERS ON PORT $port"
  local rows=() r proto laddr proc
  if ! have ss; then
    echo "  ss is not installed (package iproute2) - skipping the local listener check"
  else
    # ss's own output is far too wide for a console: keep the three columns that
    # matter and squeeze users:(("name",pid=N,... )) down to "name pid N".
    mapfile -t rows < <(ss -lntup 2>/dev/null | awk -v p=":$port" 'NR>1 && $5 ~ p"$"')
    if [ "${#rows[@]}" -eq 0 ]; then
      echo "  nothing on this box is listening on TCP/UDP $port"
    else
      printf "  %-6s %-26s %s\n" "PROTO" "LOCAL ADDRESS" "PROCESS"
      loopback_only=1
      for r in "${rows[@]}"; do
        proto=$(printf '%s' "$r" | awk '{print $1}')
        laddr=$(printf '%s' "$r" | awk '{print $5}')
        proc=$(printf '%s' "$r" | grep -oE '\(\("[^"]+",pid=[0-9]+' | head -1 | sed 's/((//; s/"//g; s/,pid=/ pid /') || true
        printf "  %-6s %-26s %s\n" "$proto" "$laddr" "${proc:-unknown}"
        case "$laddr" in
          127.*|\[::1\]:*) : ;;
          *) loopback_only=0 ;;
        esac
      done
    fi
  fi
  if [ "$loopback_only" -eq 1 ]; then
    echo
    echo "  NOTE: it is bound to loopback only. It works from this box and can never"
    echo "  be reached from anywhere else, no matter what the firewall says."
  fi

  echo
  echo "OUTBOUND TEST"
  t0=$(date +%s%N)
  rc=0
  # bash's /dev/tcp is used rather than nc because it needs no package at all;
  # timeout bounds it because a filtered (DROP) port hangs until the kernel
  # gives up, which can be over a minute. The address and port go in as
  # positional arguments, never spliced into the -c string, so no input of any
  # shape can become code.
  err=$(timeout 5 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$ip" "$port" 2>&1) || rc=$?
  t1=$(date +%s%N)
  ms=$(( (t1 - t0) / 1000000 ))
  if [ "$rc" -eq 0 ]; then
    printf "  OPEN - connected to %s:%s in %d ms\n" "$ip" "$port" "$ms"
  else
    # Judge on the reason, not on elapsed time. "Network is unreachable" comes
    # back in a millisecond just like a refusal does, and calling that CLOSED
    # would send the operator hunting for a service when the real fault is a
    # missing route - the opposite end of the problem.
    case "$err" in
      *"Connection refused"*)
        printf "  CLOSED - %s:%s refused the connection after %d ms\n" "$ip" "$port" "$ms"
        echo "  The host is reachable and answered; nothing is listening there."
        ;;
      *"unreachable"*|*"No route to host"*)
        printf "  NO ROUTE - the kernel could not even reach %s (%d ms)\n" "$ip" "$ms"
        echo "  This is a routing or link fault on this box, not a firewall at the"
        echo "  far end. Check the route decision and gateway in menu 1 first."
        ;;
      *)
        # timeout exits 124 when it had to kill the child, which is the precise
        # signature of a silent DROP - nothing came back at all.
        if [ "$rc" -eq 124 ]; then
          printf "  FILTERED - no answer at all from %s:%s after 5s\n" "$ip" "$port"
          echo "  A silent drop means a firewall in the path, not a closed port."
        else
          printf "  FAILED - %s:%s did not connect after %d ms\n" "$ip" "$port" "$ms"
          printf "  %s\n" "${err:-no error text available}"
        fi
        ;;
    esac
    echo
    echo "  Local firewall state: $(fw_line)"
    if have ufw; then
      ufw status 2>/dev/null | grep -E "(^|[^0-9])$port([^0-9]|$)" | sed 's/^/  ufw: /' || true
    fi
    if have firewall-cmd; then
      firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -E "^$port/" | sed 's/^/  firewalld: /' || true
    fi
  fi
  echo
  echo "  UDP is not tested here on purpose: a silent UDP port and an open one"
  echo "  look identical, so a 'result' would be a guess dressed up as a fact."
  return 0
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
show_header() {
  local h dev r4 gw dns fw
  h=$(hostname) || true
  dev=$(default_dev)
  r4=""
  if [ -n "$dev" ]; then
    r4=$(ip -4 -o addr show dev "$dev" 2>/dev/null | awk '{print $4; exit}') || true
  fi
  gw=$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}') || true
  # A resolver-heavy box (many search domains, IPv6 upstreams) produces a line
  # far wider than a console; cut it so the header never wraps and destroys the
  # alignment of everything under it.
  dns=$(list_resolvers | paste -sd' ' - | cut -c1-58) || true
  fw=$(fw_line)
  echo "==========================================================================="
  printf " net-diag - network diagnostics%*shost: %s\n" 20 "" "${h:-?}"
  echo "==========================================================================="
  printf " uplink    : %s\n" "${dev:-no default route} ${r4:-}"
  printf " gateway   : %s\n" "${gw:-none}"
  printf " resolvers : %s\n" "${dns:-none configured}"
  printf " firewall  : %s\n" "$fw"
  echo "---------------------------------------------------------------------------"
}

while :; do
  echo
  show_header
  cat <<'MENU'
  1) Overview             interfaces, routes, route decision, public IP
  2) Ping test            loss and min/avg/max/mdev to one target
  3) Continuous quality   1 probe/sec for N sec - loss %, jitter, outages
  4) mtr / traceroute     per-hop loss along the path
  5) DNS check            each resolver in turn, plus 8.8.8.8 and 1.1.1.1
  6) MTU discovery        largest packet that survives the path
  7) Port reachability    can we reach host:port, and who listens locally
MENU
  echo
  read -rp "Choose 1-7 [Enter = quit]: " CHOICE || true
  case "$CHOICE" in
    ""|q|Q) echo "Bye."; exit 0 ;;
    1) do_overview ;;
    2) do_ping ;;
    3) do_quality ;;
    4) do_trace ;;
    5) do_dns ;;
    6) do_mtu ;;
    7) do_port ;;
    *) echo "Invalid choice." ;;
  esac
  pause
done
SCRIPT
chmod +x /usr/local/sbin/net-diag
echo "Installed. Run:  sudo net-diag"
EOF

sudo net-diag
