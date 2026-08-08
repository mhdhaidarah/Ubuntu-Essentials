#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/dns-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# ------------------------------------------------------------------ settings
BKROOT="/root/dns-backups"
NETPLAN_WIZ="/etc/netplan/99-dns-wizard.yaml"
RESOLVED_WIZ="/etc/systemd/resolved.conf.d/99-dns-wizard.conf"
RESOLVCONF_HEAD="/etc/resolvconf/resolv.conf.d/head"
PROBE_NAMES="one.one.one.one google.com deb.debian.org"
BK=""

# Scratch space for command output we want to show the operator.  A fixed
# /tmp/<name> path is writable-by-anyone territory: any local user can plant a
# symlink there and make root's redirect land wherever they like.  mktemp -d
# gives us a 0700 directory nobody else can pre-create.
WORKDIR="$(mktemp -d /tmp/dns-wizard.XXXXXX)" || WORKDIR="/root/.dns-wizard.tmp"
mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
trap 'rm -rf "$WORKDIR"' EXIT
NPERR="$WORKDIR/netplan.err"

hr()  { printf '%s\n' "------------------------------------------------------------"; }
say() { printf '%s\n' "$*"; }

# ------------------------------------------------------------ state gathering
# Everything here writes globals instead of echoing, because several of the
# commands we call (systemctl is-active, resolvectl) print a useful answer AND
# exit non-zero at the same time.  With `set -e` a bare $(...) would take that
# exit status and kill the script mid-report, so every capture ends in `|| true`
# and every decision is made by testing the VARIABLE, never the exit status.
detect_state() {
  RESOLVED_LOAD="$(systemctl show -p LoadState --value systemd-resolved 2>/dev/null)" || true
  RESOLVED_LOAD="${RESOLVED_LOAD:-not-found}"
  RESOLVED_ACTIVE="$(systemctl is-active systemd-resolved 2>/dev/null)" || true
  RESOLVED_ACTIVE="${RESOLVED_ACTIVE:-unknown}"
  RESOLVED_ENABLED="$(systemctl is-enabled systemd-resolved 2>/dev/null)" || true
  RESOLVED_ENABLED="${RESOLVED_ENABLED:-unknown}"

  # What /etc/resolv.conf actually IS.  The target it resolves to is the whole
  # story: the same three nameserver lines mean completely different things
  # depending on who owns the file.
  RC_KIND="missing"; RC_TARGET=""; RC_LINK=""; RC_CLASS="none"
  if [ -L /etc/resolv.conf ]; then
    RC_KIND="symlink"
    RC_LINK="$(readlink /etc/resolv.conf 2>/dev/null)" || true
    RC_TARGET="$(readlink -f /etc/resolv.conf 2>/dev/null)" || true
  elif [ -f /etc/resolv.conf ]; then
    RC_KIND="file"; RC_TARGET="/etc/resolv.conf"
  fi
  case "$RC_TARGET" in
    /run/systemd/resolve/stub-resolv.conf) RC_CLASS="stub" ;;
    /run/systemd/resolve/resolv.conf)      RC_CLASS="resolved-uplink" ;;
    /usr/lib/systemd/resolv.conf|/lib/systemd/resolv.conf) RC_CLASS="systemd-static" ;;
    /run/resolvconf/resolv.conf|/etc/resolvconf/run/resolv.conf) RC_CLASS="resolvconf" ;;
    /etc/resolv.conf)                      RC_CLASS="plainfile" ;;
    "")                                    RC_CLASS="none" ;;
    *)                                     RC_CLASS="other" ;;
  esac
  if [ "$RC_CLASS" = "plainfile" ] && grep -qi "NetworkManager" /etc/resolv.conf 2>/dev/null; then
    RC_CLASS="networkmanager"
  fi
  if [ "$RC_CLASS" = "plainfile" ] && grep -qi "cloud-init" /etc/resolv.conf 2>/dev/null; then
    RC_CLASS="cloud-init"
  fi
  # mapfile replaces the array wholesale, so a re-run after a change cannot
  # leave stale servers behind from the previous detect_state.
  RC_NS=()
  mapfile -t RC_NS < <(grep -E '^[[:space:]]*nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}') || true
  RC_NS_STR="${RC_NS[*]:-none}"
  [ -n "$RC_NS_STR" ] || RC_NS_STR="none"

  # Is the file frozen with chattr +i?  People do this to stop DHCP clobbering
  # it and then forget; every later edit silently fails with EPERM.  We need to
  # know before we try, because under `set -e` a failed rm would abort the
  # wizard half way through a rollback.
  RC_IMMUTABLE="no"
  if [ "$RC_KIND" = "file" ] && command -v lsattr >/dev/null 2>&1; then
    if lsattr -d /etc/resolv.conf 2>/dev/null | awk '{print $1}' | grep -q 'i'; then RC_IMMUTABLE="yes"; fi
  fi

  # glibc consults nsswitch BEFORE resolv.conf.  If the hosts line contains
  # "resolve", most programs ask systemd-resolved over its socket and never
  # read resolv.conf at all -- this is the single most common surprise.
  NSS_HOSTS="$(grep -E '^hosts:' /etc/nsswitch.conf 2>/dev/null | sed 's/^hosts:[[:space:]]*//')" || true
  NSS_HOSTS="${NSS_HOSTS:-unknown}"

  PRIMARY_IF="$(ip route show default 2>/dev/null | awk '/^default/{print $5; exit}')" || true

  RESOLVECTL_DNS=""
  RESOLVECTL_CUR=""
  if [ "$RESOLVED_ACTIVE" = "active" ] && command -v resolvectl >/dev/null 2>&1; then
    # Keep only links that actually carry servers: a busy Docker host lists a
    # dozen empty veth links and the real answer scrolls off the screen.
    RESOLVECTL_DNS="$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2 ~ /[0-9A-Fa-f]/')" || true
    RESOLVECTL_CUR="$(resolvectl status 2>/dev/null | grep -m1 'Current DNS Server' | sed 's/.*: //')" || true
  fi

  # Anything listening on port 53 locally (resolved stub, dnsmasq, bind9,
  # unbound, pi-hole) changes what "127.0.0.x" in resolv.conf means.
  # The column holding the local address moves depending on which families ss
  # was asked for (no Netid column when a single protocol is selected), so scan
  # every field for one ending in :53 instead of trusting a position.
  LISTEN53="$(ss -lntup 2>/dev/null | awk 'NR>1{a="";p="";for(i=1;i<=NF;i++) if ($i ~ /:53$/) {a=$i; break}
      if (a!="") { if (match($0,/users:\(\("[^"]+/)) p=substr($0,RSTART+9,RLENGTH-9)
                   print a (p!="" ? "(" p ")" : "") }}' | sort -u | tr '\n' ' ')" || true
  LISTEN53="${LISTEN53:-none}"

  NETPLAN_DNS_FILES=""
  if [ -d /etc/netplan ]; then
    NETPLAN_DNS_FILES="$(grep -l -E 'nameservers' /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null | tr '\n' ' ')" || true
  fi
  NETPLAN_SECTION=""
  if command -v netplan >/dev/null 2>&1 && [ -n "${PRIMARY_IF:-}" ]; then
    NETPLAN_SECTION="$(netplan_section_for "$PRIMARY_IF")" || NETPLAN_SECTION=""
  fi

  FIREWALL="none"
  UFW_STATE="$(ufw status 2>/dev/null | head -1)" || true
  if printf '%s' "${UFW_STATE:-}" | grep -q "active"; then FIREWALL="ufw"; fi
  FW_STATE="$(systemctl is-active firewalld 2>/dev/null)" || true
  if [ "${FW_STATE:-}" = "active" ]; then
    if [ "$FIREWALL" = "none" ]; then FIREWALL="firewalld"; else FIREWALL="ufw+firewalld"; fi
  fi

  verdict
}

# One line saying which layer actually decides where a lookup goes.  Order
# matters here: the earlier cases are the ones that make the later evidence
# irrelevant.
verdict() {
  if [ "$RC_CLASS" = "stub" ] && [ "$RESOLVED_ACTIVE" = "active" ]; then
    WINNER="systemd-resolved. resolv.conf only names the local stub 127.0.0.53, so editing it changes NOTHING -- the real servers are the per-link ones below."
  elif [ "$RC_CLASS" = "stub" ]; then
    WINNER="NOBODY. resolv.conf points at 127.0.0.53 but systemd-resolved is $RESOLVED_ACTIVE, so nothing is listening there. DNS is broken until resolved starts or resolv.conf is repointed."
  elif [ "$RC_CLASS" = "resolved-uplink" ] && [ "$RESOLVED_ACTIVE" = "active" ]; then
    WINNER="systemd-resolved in no-stub mode: it WRITES the uplink servers into resolv.conf, so hand edits there are overwritten on the next link change."
  elif [ "$RC_CLASS" = "systemd-static" ]; then
    WINNER="systemd's static resolv.conf (a fixed 127.0.0.53 stub file). Same as the stub case: edit resolved, not resolv.conf."
  elif [ "$RESOLVED_ACTIVE" = "active" ] && printf '%s' "$NSS_HOSTS" | grep -qw resolve; then
    WINNER="split. nsswitch sends normal programs to systemd-resolved, while dig/curl-with-c-ares style tools that read resolv.conf get ${RC_NS_STR}. Set both or expect inconsistent answers."
  elif [ "$RC_CLASS" = "resolvconf" ]; then
    WINNER="the resolvconf package. Edits to /etc/resolv.conf are regenerated away -- change /etc/resolvconf/resolv.conf.d/head instead."
  elif [ "$RC_CLASS" = "networkmanager" ]; then
    WINNER="NetworkManager, which rewrites resolv.conf from the active connection profile."
  elif [ "$RC_CLASS" = "cloud-init" ]; then
    WINNER="cloud-init wrote this resolv.conf; it may be rewritten on the next boot unless cloud-init network config is disabled."
  elif [ "$RC_CLASS" = "plainfile" ]; then
    WINNER="the plain file /etc/resolv.conf itself: ${RC_NS_STR}. Watch out for a DHCP client rewriting it."
  else
    WINNER="unclear -- /etc/resolv.conf is $RC_KIND. Investigate before changing anything."
  fi
}

# Find which netplan section (ethernets/wifis/bonds/...) declares an interface.
# Written as an indentation walk rather than a fixed-width regex because mawk's
# support for {n} intervals is not something to bet a network config on.
netplan_section_for() {
  local ifc="$1" f out=""
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [ -e "$f" ] || continue
    out="$(awk -v ifc="$ifc" '
      { line=$0; sub(/#.*/,"",line)
        if (line ~ /^[ \t]*$/) next
        ind = match(line, /[^ \t]/) - 1
        key = line; sub(/^[ \t]*/,"",key); sub(/:.*/,"",key); gsub(/["'"'"']/,"",key)
        if (ind > 0 && key ~ /^(ethernets|wifis|bonds|bridges|vlans|vrfs|tunnels|modems)$/) { sec=key; secind=ind; next }
        if (sec != "" && ind > secind && key == ifc) { print sec; exit }
      }' "$f")" || true
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
  done
  return 1
}

# Does this interface take its IPv4 config from DHCP?  networkd drops a lease
# file per ifindex, which is exact.  The netplan grep behind it is only a hint
# -- it matches dhcp4 on ANY interface, not necessarily this one -- which is
# precisely why apply_netplan retries once without dhcp4-overrides instead of
# trusting this answer.
iface_uses_dhcp4() {
  local ifc="$1" idx=""
  idx="$(cat "/sys/class/net/$ifc/ifindex" 2>/dev/null)" || true
  if [ -n "$idx" ] && [ -f "/run/systemd/netif/leases/$idx" ]; then return 0; fi
  if grep -qE "dhcp4:[[:space:]]*(true|yes)" /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null; then return 0; fi
  return 1
}

valid_ip() {
  local ip="$1" o
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    for o in ${ip//./ }; do
      if [ "$o" -gt 255 ]; then return 1; fi
    done
    return 0
  fi
  if [[ "$ip" == *:* ]] && [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]]; then return 0; fi
  return 1
}

# ------------------------------------------------------------------- reports
print_summary() {
  detect_state
  hr
  printf "  %-16s %s\n" "resolved:"     "$RESOLVED_ACTIVE"
  printf "  %-16s %s\n" "resolv.conf:"  "$RC_KIND${RC_LINK:+ -> $RC_LINK}  [$RC_CLASS]"
  printf "  %-16s %s\n" "servers in it:" "$RC_NS_STR"
  printf "  %-16s %s\n" "IN CHARGE:"    "$WINNER"
  hr
}

# Every conditional line below is a full `if`, never `[ x ] && printf`.  A
# trailing AND-list that tests false makes the whole function return 1, and
# under `set -e` the caller then dies silently in the middle of the menu.
print_truth() {
  detect_state
  hr
  say "  THE TRUTH ABOUT DNS ON THIS BOX"
  hr
  printf "  systemd-resolved   : unit=%s  active=%s  enabled=%s\n" "$RESOLVED_LOAD" "$RESOLVED_ACTIVE" "$RESOLVED_ENABLED"
  printf "  /etc/resolv.conf   : %s\n" "$RC_KIND"
  if [ -n "$RC_LINK" ];   then printf "                       symlink -> %s\n" "$RC_LINK"; fi
  if [ -n "$RC_TARGET" ]; then printf "                       resolves to %s\n" "$RC_TARGET"; fi
  printf "                       classified as: %s\n" "$RC_CLASS"
  printf "                       nameserver lines: %s\n" "$RC_NS_STR"
  if [ "$RC_IMMUTABLE" = "yes" ]; then
    printf "                       *** IMMUTABLE (chattr +i) -- every edit fails silently\n"
  fi
  printf "  nsswitch hosts     : %s\n" "$NSS_HOSTS"
  printf "  listening on :53   : %s\n" "$LISTEN53"
  echo
  if [ -n "$RESOLVECTL_DNS" ]; then
    say "  What systemd-resolved is really using (links that have servers):"
    printf '%s\n' "$RESOLVECTL_DNS" | sed 's/^/    /'
    if [ -n "$RESOLVECTL_CUR" ]; then printf "    Current DNS server in use: %s\n" "$RESOLVECTL_CUR"; fi
  elif [ "$RESOLVED_ACTIVE" = "active" ]; then
    say "  systemd-resolved is running but no link has any DNS server configured."
  else
    say "  systemd-resolved is not answering -- no per-link view available."
  fi
  echo
  if command -v netplan >/dev/null 2>&1; then
    printf "  netplan            : installed; default route is on %s\n" "${PRIMARY_IF:-unknown}"
    if [ -n "$NETPLAN_SECTION" ]; then
      printf "                       %s is declared under '%s:' -- netplan manages it\n" "$PRIMARY_IF" "$NETPLAN_SECTION"
    else
      printf "                       %s is NOT declared in /etc/netplan -- netplan is not driving it\n" "${PRIMARY_IF:-it}"
    fi
    if [ -n "$NETPLAN_DNS_FILES" ]; then
      printf "                       files supplying nameservers: %s\n" "$NETPLAN_DNS_FILES"
      grep -A3 -H 'nameservers' /etc/netplan/*.yaml /etc/netplan/*.yml 2>/dev/null | sed 's/^/                         /' || true
    else
      printf "                       no nameservers set in netplan"
      if [ -n "${PRIMARY_IF:-}" ] && iface_uses_dhcp4 "$PRIMARY_IF"; then
        printf " -- so the DHCP server on %s is supplying them\n" "$PRIMARY_IF"
      else
        printf "\n"
      fi
    fi
  else
    say "  netplan            : not installed"
  fi
  printf "  firewall           : %s\n" "$FIREWALL"
  hr
  say "  WHICH LAYER WINS:"
  printf "    %s\n" "$WINNER"
  hr
}

# ------------------------------------------------------------ backup/rollback
new_backup() {
  TS="$(date +%Y%m%d-%H%M%S)"
  BK="$BKROOT/$TS"
  mkdir -p "$BK/netplan" "$BK/resolved.conf.d"
  chmod 700 "$BKROOT" "$BK"
  # cp -a on a symlink copies the LINK, not its target, which is exactly what
  # we need: restoring must recreate the same arrangement, not a snapshot of
  # whatever resolved happened to have generated.
  cp -a /etc/resolv.conf "$BK/resolv.conf" 2>/dev/null || true
  cp -a /etc/netplan/*.yaml /etc/netplan/*.yml "$BK/netplan/" 2>/dev/null || true
  cp -a /etc/systemd/resolved.conf.d/*.conf "$BK/resolved.conf.d/" 2>/dev/null || true
  cp -a /etc/systemd/resolved.conf "$BK/resolved.conf" 2>/dev/null || true
  # Record the resolvconf head either way: if it did not exist, rollback has to
  # DELETE the one we are about to create, not "restore" a file that was never
  # there.  A missing marker file is the only way to tell those apart later.
  if [ -e "$RESOLVCONF_HEAD" ]; then
    cp -a "$RESOLVCONF_HEAD" "$BK/resolvconf-head" 2>/dev/null || true
  else
    : > "$BK/resolvconf-head-absent"
  fi
  say "Backup: $BK"
}

# Remove /etc/resolv.conf so it can be replaced.  Split out because an
# immutable file makes plain `rm -f` exit 1, and under `set -e` that would
# abandon a rollback half done -- the worst possible moment to quit.
clear_resolv_conf() {
  if [ "$RC_IMMUTABLE" = "yes" ] && command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
  fi
  rm -f /etc/resolv.conf 2>/dev/null || true
  if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then return 1; fi
  return 0
}

rollback() {
  local bk="$1"
  # Never let an empty or vanished path turn into cp of "/netplan/*" -- the
  # rollback is the one code path that must not itself break the machine.
  if [ -z "$bk" ] || [ ! -d "$bk" ]; then
    say "*** No usable backup directory ($bk) -- cannot roll back automatically."
    emergency_resolv
    return 1
  fi
  say "Rolling back from $bk ..."
  rm -f "$NETPLAN_WIZ" "$RESOLVED_WIZ"
  if [ -e "$bk/resolv.conf" ] || [ -L "$bk/resolv.conf" ]; then
    if clear_resolv_conf; then
      cp -a "$bk/resolv.conf" /etc/resolv.conf 2>/dev/null || true
    else
      say "*** Could not remove /etc/resolv.conf (immutable?); leaving it as it is."
    fi
  fi
  cp -a "$bk"/netplan/*.yaml "$bk"/netplan/*.yml /etc/netplan/ 2>/dev/null || true
  cp -a "$bk"/resolved.conf.d/*.conf /etc/systemd/resolved.conf.d/ 2>/dev/null || true
  # The resolvconf head is edited in place rather than via a drop-in, so it is
  # the one file a rollback has to undo by hand.
  if [ -f "$bk/resolvconf-head-absent" ]; then
    rm -f "$RESOLVCONF_HEAD"
  elif [ -f "$bk/resolvconf-head" ]; then
    cp -a "$bk/resolvconf-head" "$RESOLVCONF_HEAD" 2>/dev/null || true
  fi
  if command -v resolvconf >/dev/null 2>&1; then resolvconf -u >/dev/null 2>&1 || true; fi
  if command -v netplan >/dev/null 2>&1; then
    netplan generate >/dev/null 2>&1 || true
    netplan apply >/dev/null 2>&1 || true
  fi
  if [ "$RESOLVED_LOAD" = "loaded" ]; then systemctl restart systemd-resolved 2>/dev/null || true; fi
  if verify_dns; then
    say "Rolled back and name resolution works again."
  else
    say "*** Rollback did not restore resolution."
    emergency_resolv
  fi
  return 0
}

# Last resort so the operator is never left on a box that cannot resolve its
# own package mirror.  A real file beats a dangling symlink every time.
emergency_resolv() {
  local A=""
  if [ -t 0 ]; then
    read -rp "Write an emergency /etc/resolv.conf with 1.1.1.1 and 8.8.8.8? [y/N]: " A || A=""
  else
    # No terminal to ask at (piped input, or called from a rollback that ran
    # after stdin was consumed).  Refusing here would leave the box with no
    # working resolver at all, so write the file and say so loudly.
    say "No terminal to ask at -- writing the emergency resolv.conf automatically."
    A="y"
  fi
  case "$A" in
    y|Y)
      if ! clear_resolv_conf; then
        say "Cannot replace /etc/resolv.conf (immutable?). Run: chattr -i /etc/resolv.conf"
        return 0
      fi
      printf '# emergency file written by dns-wizard %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' "$(date)" > /etc/resolv.conf
      chmod 644 /etc/resolv.conf
      if verify_dns; then
        say "Emergency resolvers work. Backups are in $BKROOT."
      else
        say "Still failing -- this is not a DNS-server problem. Check routing and the firewall (${FIREWALL})."
      fi
      ;;
    *) say "Left as is. Backups are in $BKROOT." ;;
  esac
  return 0
}

# The system path, exactly as a normal program sees it (nsswitch included).
# Retried because resolved and networkd need a moment after a reconfigure.
verify_dns() {
  local n try
  for try in 1 2 3; do
    for n in $PROBE_NAMES; do
      if getent ahostsv4 "$n" >/dev/null 2>&1; then return 0; fi
    done
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- query tool
QTOOL=""
pick_query_tool() {
  if command -v python3 >/dev/null 2>&1; then QTOOL="python3"
  elif command -v dig >/dev/null 2>&1; then QTOOL="dig"
  elif command -v nslookup >/dev/null 2>&1; then QTOOL="nslookup"
  else QTOOL=""; fi
}

# Prints "<ms> <answer>" on success.  python3 is preferred over dig because it
# is present on every Ubuntu server image, so the test menu keeps working on a
# box whose DNS is too broken to install dnsutils.
query_one() {
  local srv="$1" nm="$2" out="" full="" t="" d=""
  case "$QTOOL" in
    python3)
      out="$(python3 - "$srv" "$nm" <<'PY'
import socket, struct, sys, time, random
srv, name = sys.argv[1], sys.argv[2]
q = b""
for label in name.strip(".").split("."):
    q += bytes([len(label)]) + label.encode()
q += b"\x00" + struct.pack(">HH", 1, 1)
tid = random.randint(0, 65535)
pkt = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0) + q
fam = socket.AF_INET6 if ":" in srv else socket.AF_INET
try:
    s = socket.socket(fam, socket.SOCK_DGRAM)
    s.settimeout(3.0)
except Exception:
    sys.exit(1)
start = time.time()
try:
    s.sendto(pkt, (srv, 53))
    while True:
        data, _ = s.recvfrom(4096)
        if len(data) >= 12 and struct.unpack(">H", data[0:2])[0] == tid:
            break
except Exception:
    sys.exit(1)
ms = (time.time() - start) * 1000.0
rcode = data[3] & 0x0F
ancount = struct.unpack(">H", data[6:8])[0]

def skip_name(buf, off):
    # A length byte >= 0xC0 is a compression pointer (2 bytes), not a label.
    while True:
        l = buf[off]
        if l >= 0xC0:
            return off + 2
        off += 1
        if l == 0:
            return off
        off += l

answer = "-"
try:
    off = skip_name(data, 12) + 4
    for _ in range(ancount):
        off = skip_name(data, off)
        rtype, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[off:off + 10])
        off += 10
        rdata = data[off:off + rdlen]
        off += rdlen
        if rtype == 1 and rdlen == 4:
            answer = socket.inet_ntop(socket.AF_INET, rdata); break
        if rtype == 28 and rdlen == 16:
            answer = socket.inet_ntop(socket.AF_INET6, rdata); break
except Exception:
    answer = "?"
if rcode != 0:
    answer = "RCODE=%d" % rcode
print("%.0f %s" % (ms, answer))
PY
)" || return 1
      ;;
    dig)
      full="$(dig +time=3 +tries=1 "@$srv" "$nm" A 2>/dev/null)" || true
      t="$(printf '%s\n' "$full" | awk '/^;; Query time:/{print $4; exit}')" || true
      d="$(printf '%s\n' "$full" | awk '$4=="A"{print $5; exit}')" || true
      if [ -z "$t" ]; then return 1; fi
      out="$t ${d:--}"
      ;;
    nslookup)
      d="$(nslookup "$nm" "$srv" 2>/dev/null | awk '/^Address: /{print $2; exit}')" || true
      if [ -z "$d" ]; then return 1; fi
      out="? $d"
      ;;
    *) return 1 ;;
  esac
  if [ -z "$out" ]; then return 1; fi
  printf '%s\n' "$out"
  return 0
}

# --------------------------------------------------------------- menu: apply
# netplan MERGES the nameserver lists it finds across files -- it does not let a
# later file replace an earlier one.  Writing 99-dns-wizard.yaml therefore ADDS
# our servers to the ones 50-cloud-init.yaml already declares, and the old
# resolver keeps answering while the operator believes the change took.  These
# three helpers exist to detect that and offer the only real cure: silencing the
# nameservers block in the other file.

# What netplan actually generated for this interface after `netplan generate`.
# Reads the backend output, not the YAML, so it is the merged truth.
generated_dns_for_iface() {
  local ifc="$1" out=""
  out="$(grep -h '^DNS=' /run/systemd/network/*"$ifc"*.network 2>/dev/null | sed 's/^DNS=//' | tr ' ' '\n')" || true
  if [ -z "$out" ]; then
    # With the NetworkManager renderer netplan emits keyfiles instead of units.
    out="$(grep -h '^dns=' /run/NetworkManager/system-connections/*"$ifc"* 2>/dev/null | sed 's/^dns=//' | tr ';' '\n')" || true
  fi
  printf '%s\n' "$out" | grep -E '^[0-9A-Fa-f.:]+$' || true
}

# Comment out the nameservers block belonging to one interface, leaving
# addresses, routes and everything else untouched.  Done as an indentation walk
# so a block is recognised by where it sits, not by a guessed column count.
strip_netplan_nameservers() {
  local f="$1" ifc="$2"
  awk -v ifc="$ifc" '
    function ind(s) { return match(s, /[^ \t]/) - 1 }
    {
      line = $0
      bare = line; sub(/#.*/, "", bare)
      if (bare ~ /^[ \t]*$/) { print line; next }
      i = ind(bare)
      key = bare; sub(/^[ \t]*/, "", key); sub(/:.*/, "", key); gsub(/["'"'"']/, "", key)
      if (inns) { if (i > nsind) { print "#dns-wizard# " line; next } ; inns = 0 }
      if (inif) {
        if (i > ifind) {
          if (key == "nameservers") { inns = 1; nsind = i; print "#dns-wizard# " line; next }
          print line; next
        }
        inif = 0
      }
      if (i > 0 && key ~ /^(ethernets|wifis|bonds|bridges|vlans|vrfs|tunnels|modems)$/) { sec = key; secind = i; print line; next }
      if (sec != "" && i > secind && key == ifc) { inif = 1; ifind = i; print line; next }
      print line
    }' "$f"
}

# Which files would actually change if we stripped them?  Comparing the stripped
# output with the original is exact -- no second parser to disagree with the one
# above.
netplan_files_with_ns_for_iface() {
  local ifc="$1" f
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    if [ ! -e "$f" ]; then continue; fi
    if [ "$f" = "$NETPLAN_WIZ" ]; then continue; fi
    if ! strip_netplan_nameservers "$f" "$ifc" | diff -q - "$f" >/dev/null 2>&1; then
      printf '%s\n' "$f"
    fi
  done
}

# Put back files this wizard edited, from the backup taken before the change.
# Kept separate because it is needed on three different unwind paths and each
# one of them is a moment where a half-edited /etc/netplan must not survive.
restore_netplan_files() {
  local list="$1" f
  if [ -z "$list" ]; then return 0; fi
  if [ -z "$BK" ] || [ ! -d "$BK/netplan" ]; then
    say "*** No backup to restore /etc/netplan from -- left as it is. Check $BKROOT."
    return 0
  fi
  for f in $list; do
    cp -a "$BK/netplan/$(basename "$f")" "$f" 2>/dev/null || true
  done
  if command -v netplan >/dev/null 2>&1; then netplan generate >/dev/null 2>&1 || true; fi
  return 0
}

apply_netplan() {
  local ifc="$1" section="$2" dns="$3" list=""
  list="$(printf '%s' "$dns" | tr -s ' ' | sed 's/^ //; s/ $//; s/ /, /g')"
  {
    echo "# written by dns-wizard on $(date)"
    echo "network:"
    echo "  version: 2"
    echo "  ${section}:"
    echo "    ${ifc}:"
    echo "      nameservers:"
    echo "        addresses: [${list}]"
    # Without use-dns:false the DHCP server's list is merged in and usually
    # wins, so the operator sets servers and sees no change at all.
    if iface_uses_dhcp4 "$ifc"; then
      echo "      dhcp4-overrides:"
      echo "        use-dns: false"
    fi
  } > "$NETPLAN_WIZ"
  # netplan refuses (or warns loudly) about world-readable configs, and this
  # file only ever holds resolver addresses, so lock it to root.
  chmod 600 "$NETPLAN_WIZ"

  say "Wrote $NETPLAN_WIZ :"
  sed 's/^/    /' "$NETPLAN_WIZ"

  if ! netplan generate 2>"$NPERR"; then
    say "netplan rejected the config:"
    sed 's/^/    /' "$NPERR"
    # The usual cause is dhcp4-overrides on an interface that is not actually
    # DHCP in the merged config; retry once without it before giving up.
    if grep -q "dhcp4-overrides" "$NETPLAN_WIZ"; then
      say "Retrying without dhcp4-overrides ..."
      # grep -v exits 1 when it prints nothing, which cannot happen here, but
      # `set -e` would kill the retry if it ever did.
      grep -v -e 'dhcp4-overrides' -e 'use-dns' "$NETPLAN_WIZ" > "$NETPLAN_WIZ.tmp" || true
      mv "$NETPLAN_WIZ.tmp" "$NETPLAN_WIZ"; chmod 600 "$NETPLAN_WIZ"
      if ! netplan generate 2>"$NPERR"; then
        sed 's/^/    /' "$NPERR"
        rm -f "$NETPLAN_WIZ"
        netplan generate >/dev/null 2>&1 || true
        return 1
      fi
    else
      rm -f "$NETPLAN_WIZ"
      netplan generate >/dev/null 2>&1 || true
      return 1
    fi
  fi

  # Now that netplan has generated the backend config, compare what it really
  # produced with what was asked for.  Anything extra is another file's list
  # being merged in, and it will keep answering queries unless we silence it.
  local gen="" g extra="" nsf files_txt="" stripped=""
  gen="$(generated_dns_for_iface "$ifc")" || true
  for g in $gen; do
    case " $dns " in
      *" $g "*) ;;
      *) extra="$extra $g" ;;
    esac
  done
  if [ -n "$extra" ]; then
    say ""
    say "WARNING: netplan merged servers from another file, so this interface would use:"
    say "   $(printf '%s' "$gen" | tr '\n' ' ')"
    say "The extra ones ($(printf '%s' "$extra" | sed 's/^ //')) come from:"
    local nsfiles=()
    mapfile -t nsfiles < <(netplan_files_with_ns_for_iface "$ifc") || true
    for nsf in "${nsfiles[@]:-}"; do
      if [ -n "$nsf" ]; then say "   $nsf"; files_txt="$files_txt $nsf"; fi
    done
    if [ -z "$files_txt" ]; then
      say "   (not from /etc/netplan -- check the renderer's own configuration)"
    else
      say "netplan has no way to replace a list, only to add to it, so those blocks have"
      say "to be commented out for your choice to be the only one. Addresses and routes"
      say "in those files are left exactly as they are, and a backup is already in $BK."
      local S=""
      read -rp "Comment out the other nameservers blocks? [y/N]: " S || S=""
      case "$S" in
        y|Y)
          for nsf in $files_txt; do
            strip_netplan_nameservers "$nsf" "$ifc" > "$WORKDIR/np.yaml"
            # Write through the existing file rather than mv'ing over it, so the
            # original owner and 0600 mode survive; netplan complains about
            # world-readable configs.
            cat "$WORKDIR/np.yaml" > "$nsf"
            stripped="$stripped $nsf"
          done
          if ! netplan generate 2>"$NPERR"; then
            say "netplan rejected the edited files -- putting them back untouched:"
            sed 's/^/    /' "$NPERR"
            restore_netplan_files "$stripped"
            rm -f "$NETPLAN_WIZ"
            netplan generate >/dev/null 2>&1 || true
            return 1
          fi
          gen="$(generated_dns_for_iface "$ifc")" || true
          say "This interface will now use: $(printf '%s' "$gen" | tr '\n' ' ')"
          ;;
        *) say "Left them in place -- expect the old servers to keep answering." ;;
      esac
    fi
  fi

  say "netplan apply briefly reconfigures ${ifc}; an SSH session normally survives it."
  local A=""
  read -rp "Apply now? [y/N]: " A || A=""
  case "$A" in
    y|Y) ;;
    # Exit 2 means "operator backed out, nothing changed" -- distinct from a
    # real failure so the caller does not run a verify/rollback cycle over a
    # configuration it never touched.
    # "Nothing changed" has to mean it: any nameservers block we commented out
    # a moment ago is put back too, or the link would be left with no servers at
    # all the next time networkd reloads.
    *) say "Not applied. Removing the file and undoing any edits."
       rm -f "$NETPLAN_WIZ"
       restore_netplan_files "$stripped"
       netplan generate >/dev/null 2>&1 || true
       return 2 ;;
  esac
  netplan apply || true
  if [ "$RESOLVED_ACTIVE" = "active" ]; then resolvectl flush-caches >/dev/null 2>&1 || true; fi
  return 0
}

apply_resolved() {
  local dns="$1" A="" perlink=""
  mkdir -p /etc/systemd/resolved.conf.d
  {
    echo "# written by dns-wizard on $(date)"
    echo "[Resolve]"
    echo "DNS=$dns"
  } > "$RESOLVED_WIZ"
  chmod 644 "$RESOLVED_WIZ"
  say "Wrote $RESOLVED_WIZ"
  if ! systemctl restart systemd-resolved; then
    say "systemd-resolved refused to restart."
    rollback "$BK"
    return 1
  fi
  # Setting resolved is pointless if programs never reach it: that happens when
  # resolv.conf is a real file with its own servers and nsswitch has no
  # "resolve" entry.  Offer the standard fix rather than leaving a no-op.
  if [ "$RC_CLASS" = "plainfile" ] || [ "$RC_CLASS" = "cloud-init" ] || [ "$RC_CLASS" = "networkmanager" ]; then
    if ! printf '%s' "$NSS_HOSTS" | grep -qw resolve; then
      say "Note: /etc/resolv.conf is a real file listing ${RC_NS_STR}, and nsswitch does"
      say "      not mention 'resolve', so most programs will keep using that file."
      read -rp "Point /etc/resolv.conf at the systemd-resolved stub? [y/N]: " A || A=""
      case "$A" in
        y|Y)
          if clear_resolv_conf; then
            ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
          else
            say "Could not replace /etc/resolv.conf (immutable?). Left it alone."
          fi
          ;;
        *) say "Left the file alone." ;;
      esac
    fi
  fi
  # A global DNS= in resolved.conf does NOT replace per-link servers: resolved
  # queries link servers as well, so a DHCP-supplied resolver keeps answering
  # and the operator sees the old address in `resolvectl status`.  Say so
  # instead of letting them believe the change took full effect.
  perlink="$(resolvectl dns 2>/dev/null | awk -F': ' 'NF>1 && $2 ~ /[0-9]/')" || true
  if [ -n "$perlink" ]; then
    say "Heads up: these links still carry their own servers, which resolved keeps using"
    say "alongside the ones you just set:"
    printf '%s\n' "$perlink" | sed 's/^/    /'
    say "To stop that permanently, turn off DHCP-supplied DNS on the link (netplan"
    say "dhcp4-overrides: use-dns: false, or NetworkManager ipv4.ignore-auto-dns yes)."
  fi
  return 0
}

apply_resolvconf() {
  local dns="$1" s
  if ! command -v resolvconf >/dev/null 2>&1; then
    say "REFUSING: /etc/resolv.conf is generated by resolvconf but the 'resolvconf'"
    say "command is missing, so the change could not be regenerated into place."
    return 1
  fi
  mkdir -p /etc/resolvconf/resolv.conf.d
  {
    echo "# Dynamic resolv.conf head -- managed by dns-wizard"
    for s in $dns; do echo "nameserver $s"; done
  } > "$RESOLVCONF_HEAD"
  resolvconf -u || true
  return 0
}

apply_plainfile() {
  local dns="$1" s tmp="$WORKDIR/resolv.conf.new"
  if [ "$RC_IMMUTABLE" = "yes" ]; then
    say "REFUSING: /etc/resolv.conf is immutable (chattr +i). Run 'chattr -i /etc/resolv.conf'"
    say "first, so the change is visible instead of silently discarded."
    return 1
  fi
  # Build the replacement first and only then swap it in: if the write failed
  # halfway (full disk, read-only /etc) the box would otherwise be left with a
  # truncated resolv.conf and no resolver at all.
  {
    echo "# written by dns-wizard on $(date)"
    for s in $dns; do echo "nameserver $s"; done
    echo "options timeout:2 attempts:2"
  } > "$tmp"
  if ! clear_resolv_conf; then
    say "REFUSING: /etc/resolv.conf could not be removed. Nothing changed."
    return 1
  fi
  cat "$tmp" > /etc/resolv.conf
  chmod 644 /etc/resolv.conf
  say "Wrote /etc/resolv.conf. A DHCP client or NetworkManager may rewrite it later;"
  say "if that happens, come back and set the resolvers at that layer instead."
  return 0
}

set_resolvers() {
  detect_state
  echo
  say "Pick the resolvers:"
  printf "  1) Google      8.8.8.8 8.8.4.4\n"
  printf "  2) Cloudflare  1.1.1.1 1.0.0.1\n"
  printf "  3) Quad9       9.9.9.9 149.112.112.112   (blocks known-malicious names)\n"
  printf "  4) Custom      type your own\n"
  printf "  Enter) cancel\n"
  local P="" NEW="" A="" s ok=1 layer="file" rc=0 pre_ok=1
  read -rp "Choose: " P || P=""
  case "$P" in
    1) NEW="8.8.8.8 8.8.4.4" ;;
    2) NEW="1.1.1.1 1.0.0.1" ;;
    3) NEW="9.9.9.9 149.112.112.112" ;;
    4) read -rp "Servers, space separated (IPv4 and/or IPv6): " NEW || NEW="" ;;
    *) say "Cancelled."; return 0 ;;
  esac
  NEW="$(printf '%s' "$NEW" | tr ',' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
  if [ -z "$NEW" ]; then
    say "REFUSING an empty list -- that would leave the box unable to resolve anything."
    return 0
  fi
  for s in $NEW; do
    if ! valid_ip "$s"; then say "Not an IP address: $s"; ok=0; fi
  done
  if [ "$ok" -ne 1 ]; then say "Nothing applied."; return 0; fi

  # Choose the layer that is actually in charge; writing to any other one looks
  # like it worked and changes nothing.
  if [ -n "$NETPLAN_SECTION" ]; then layer="netplan"
  elif [ "$RESOLVED_ACTIVE" = "active" ]; then layer="resolved"
  elif [ "$RC_CLASS" = "resolvconf" ]; then layer="resolvconf"
  else layer="file"; fi

  echo
  case "$layer" in
    netplan)    say "Layer in charge: netplan (it declares $PRIMARY_IF under ${NETPLAN_SECTION}:)." ;;
    resolved)   say "Layer in charge: systemd-resolved (netplan does not manage ${PRIMARY_IF:-this link})." ;;
    resolvconf) say "Layer in charge: the resolvconf package." ;;
    file)       say "Layer in charge: the plain file /etc/resolv.conf." ;;
  esac
  say "New servers: $NEW"
  read -rp "Apply there? [y/N]: " A || A=""
  case "$A" in y|Y) ;; *) say "Cancelled."; return 0 ;; esac

  # Record whether lookups worked BEFORE the change.  If they were already
  # broken -- the usual reason someone runs this wizard -- rolling back on a
  # failed verify would just restore the broken state and hide the new, correct
  # settings.  Only roll back when we actually made things worse.
  if verify_dns; then pre_ok=1; else pre_ok=0; fi

  new_backup
  case "$layer" in
    netplan)    apply_netplan "$PRIMARY_IF" "$NETPLAN_SECTION" "$NEW" || rc=$? ;;
    resolved)   apply_resolved "$NEW" || rc=$? ;;
    resolvconf) apply_resolvconf "$NEW" || rc=$? ;;
    file)       apply_plainfile "$NEW" || rc=$? ;;
  esac
  if [ "$rc" -eq 2 ]; then return 0; fi
  if [ "$rc" -ne 0 ]; then say "Nothing applied."; return 0; fi

  if verify_dns; then
    say "Name resolution still works."
    print_summary
  elif [ "$pre_ok" -eq 1 ]; then
    say "*** Lookups FAILED after the change -- rolling back so you are not stranded."
    rollback "$BK"
  else
    say "*** Lookups still fail -- but they were already failing BEFORE this change,"
    say "    so the new settings are kept (rolling back would only restore the fault)."
    say "    Check routing (ip route), the firewall ($FIREWALL) and outbound udp/53."
    emergency_resolv
  fi
  return 0
}

# ---------------------------------------------------------------- menu: test
test_resolvers() {
  detect_state
  pick_query_tool
  if [ -z "$QTOOL" ]; then
    say "No query tool found (python3, dig or nslookup). Install dnsutils to use this."
    return 0
  fi
  local cands=() seen="" s extra="" nm="" ms ans line t0 t1
  # Querying the stub itself exercises resolved end to end: its cache, its
  # per-link routing and the uplink behind it.
  if [ "$RESOLVED_ACTIVE" = "active" ]; then cands+=("127.0.0.53"); fi
  if [ -n "$RESOLVECTL_DNS" ]; then
    while read -r s; do
      if [ -n "$s" ]; then cands+=("$s"); fi
    done < <(printf '%s\n' "$RESOLVECTL_DNS" | sed 's/^[^:]*://' | tr ' ' '\n' | grep -E '^[0-9A-Fa-f.:]+$')
  fi
  for s in "${RC_NS[@]:-}"; do
    if [ -n "$s" ]; then cands+=("$s"); fi
  done
  read -rp "Also test another server (Enter for none): " extra || extra=""
  if [ -n "$extra" ]; then
    if valid_ip "$extra"; then cands+=("$extra"); else say "Ignoring '$extra' -- not an IP."; fi
  fi
  read -rp "Name to resolve [google.com]: " nm || nm=""
  nm="${nm:-google.com}"

  if [ "${#cands[@]}" -eq 0 ]; then
    say "No resolvers to test: nothing is configured anywhere. Use option 2 first."
    return 0
  fi
  echo
  printf "  %-24s %-8s %-8s %s\n" "SERVER" "RESULT" "TIME" "ANSWER"
  printf "  %-24s %-8s %-8s %s\n" "------" "------" "----" "------"
  for s in "${cands[@]}"; do
    # Deduplicate by hand: the same server usually shows up in both resolvectl
    # and resolv.conf, and a "function printed nothing" guard is useless here
    # because query_one legitimately prints nothing when it fails.
    case " $seen " in *" $s "*) continue ;; esac
    seen="$seen $s"
    line="$(query_one "$s" "$nm")" || line=""
    if [ -z "$line" ]; then
      printf "  %-24s %-8s %-8s %s\n" "$s" "FAIL" "-" "no answer in 3s"
    else
      ms="${line%% *}"; ans="${line#* }"
      printf "  %-24s %-8s %-8s %s\n" "$s" "ok" "${ms}ms" "$ans"
    fi
  done
  echo
  t0="$(date +%s%N)"
  if getent ahostsv4 "$nm" >/dev/null 2>&1; then
    t1="$(date +%s%N)"
    printf "  system path (nsswitch + resolv.conf): ok in %sms\n" "$(( (t1 - t0) / 1000000 ))"
  else
    printf "  system path (nsswitch + resolv.conf): FAILED -- this is what programs see\n"
    # An `if`, not `[ ... ] && printf`: as the last statement of the function a
    # false test would return 1 and, under `set -e`, quietly end the wizard.
    if [ "$FIREWALL" != "none" ]; then
      printf "  A firewall is active (%s); check that outbound udp/53 is allowed.\n" "$FIREWALL"
    fi
  fi
  return 0
}

# --------------------------------------------------------------- menu: flush
flush_cache() {
  detect_state
  local before="" after="" svc st
  if [ "$RESOLVED_ACTIVE" = "active" ]; then
    before="$(resolvectl statistics 2>/dev/null | awk '/Current Cache Size/{print $NF; exit}')" || true
    if resolvectl flush-caches 2>/dev/null; then
      after="$(resolvectl statistics 2>/dev/null | awk '/Current Cache Size/{print $NF; exit}')" || true
      printf "  systemd-resolved cache flushed: %s -> %s entries\n" "${before:-?}" "${after:-?}"
    else
      say "  resolvectl flush-caches failed; trying the older command."
      systemd-resolve --flush-caches 2>/dev/null || say "  Could not flush."
    fi
  else
    say "  systemd-resolved is $RESOLVED_ACTIVE -- nothing of its cache to flush."
    say "  glibc itself does not cache, so lookups already go straight to ${RC_NS_STR}."
  fi
  if systemctl is-active nscd >/dev/null 2>&1; then
    nscd -i hosts 2>/dev/null || true
    say "  nscd hosts cache invalidated."
  fi
  for svc in dnsmasq unbound bind9 named; do
    st="$(systemctl is-active "$svc" 2>/dev/null)" || true
    if [ "${st:-}" = "active" ]; then
      say "  NOTE: $svc is running on this box and caches separately -- restart it to clear that cache."
    fi
  done
  return 0
}

# ------------------------------------------------------------- menu: restore
restore_defaults() {
  detect_state
  echo
  say "This restores the distribution arrangement:"
  say "  - delete $NETPLAN_WIZ and $RESOLVED_WIZ if this wizard created them"
  say "  - enable and start systemd-resolved"
  say "  - /etc/resolv.conf -> ../run/systemd/resolve/stub-resolv.conf"
  say "  - netplan apply"
  # Repointing resolv.conf at 127.0.0.53 is only safe if something will be
  # listening there.  Refuse in both cases where it will not be, rather than
  # handing back a box that resolves nothing.
  if [ "$RESOLVED_LOAD" != "loaded" ]; then
    echo
    say "REFUSING: systemd-resolved is not installed here ($RESOLVED_LOAD), so there is no"
    say "stub to point at. Repointing resolv.conf at 127.0.0.53 would leave this box with"
    say "no DNS at all. Install systemd-resolved first, or set resolvers from the menu."
    return 0
  fi
  if [ "$RESOLVED_ENABLED" = "masked" ]; then
    echo
    say "REFUSING: systemd-resolved is masked, so it cannot be started and the stub would"
    say "never answer. Run 'systemctl unmask systemd-resolved' first if you want it back."
    return 0
  fi
  local A=""
  read -rp "Type RESTORE to continue: " A || A=""
  if [ "$A" != "RESTORE" ]; then say "Cancelled."; return 0; fi

  new_backup
  rm -f "$NETPLAN_WIZ" "$RESOLVED_WIZ"
  if [ "$RC_IMMUTABLE" = "yes" ]; then
    say "Clearing the immutable bit on /etc/resolv.conf so it can be replaced."
  fi
  systemctl enable systemd-resolved >/dev/null 2>&1 || true
  systemctl restart systemd-resolved || true
  if clear_resolv_conf; then
    ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
  else
    say "*** Could not replace /etc/resolv.conf -- leaving the existing one in place."
  fi
  if command -v netplan >/dev/null 2>&1; then
    if netplan generate 2>"$NPERR"; then
      netplan apply || true
    else
      say "netplan config is invalid (pre-existing, not from this restore):"
      sed 's/^/    /' "$NPERR"
    fi
  fi
  if verify_dns; then
    say "Defaults restored and lookups work."
    print_summary
  else
    say "*** Lookups FAILED after restoring -- rolling back."
    rollback "$BK"
  fi
  return 0
}

# ------------------------------------------------------------------ the menu
mkdir -p "$BKROOT"; chmod 700 "$BKROOT"
print_truth
while true; do
  echo
  say "  1) Show the truth (full detail)"
  say "  2) Set resolvers"
  say "  3) Test resolvers (timed, per server)"
  say "  4) Flush the DNS cache"
  say "  5) Restore the distribution defaults"
  say "  Enter) quit"
  C=""
  # A failed read means EOF (stdin was a pipe, or the terminal went away).
  # Treating that as "quit" is what stops this loop spinning forever.
  read -rp "Choose: " C || { say "Bye."; exit 0; }
  case "$C" in
    1) print_truth ;;
    2) set_resolvers ;;
    3) test_resolvers ;;
    4) flush_cache ;;
    5) restore_defaults ;;
    "") say "Bye."; exit 0 ;;
    *) say "Unknown choice." ;;
  esac
  echo
  read -rp "Press Enter for the menu..." _ || true
  print_summary
done
SCRIPT
chmod +x /usr/local/sbin/dns-wizard
echo "Installed. Run:  sudo dns-wizard"
EOF

sudo dns-wizard