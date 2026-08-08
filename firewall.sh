#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/fw-wizard <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# fw-wizard - a ufw front end whose first job is NOT to lock you out.
#
# Everything here is built on one idea: the firewall's rules and the sockets
# that are actually listening are two different truths, and every ufw disaster
# is a disagreement between them. So we always read both, side by side, and we
# refuse to turn the firewall on until the port carrying THIS session is in it.

BKDIR=/var/backups/fw-wizard

# --- basic state -------------------------------------------------------------

# `systemctl is-active` PRINTS "inactive"/"failed" and exits non-zero, so it can
# neither be used bare under `set -e` nor with a `|| echo` fallback (that would
# yield two lines). Capture with `|| true`, then test the variable.
svc_state() { local s; s=$(systemctl is-active "$1" 2>/dev/null) || true; echo "${s:-unknown}"; }

firewalld_active() { [ "$(svc_state firewalld)" = "active" ]; }

ufw_active() { ufw status 2>/dev/null | grep -qi '^Status: active'; }

# The default incoming policy decides whether enabling ufw closes anything at
# all. While ufw is INACTIVE, `ufw status verbose` prints only the status line,
# so the running value does not exist yet - read the policy that WILL apply from
# /etc/default/ufw instead of reporting "unknown".
default_incoming() {
  local d=""
  d=$(ufw status verbose 2>/dev/null | sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p') || true
  if [ -z "$d" ]; then
    d=$(sed -n 's/^DEFAULT_INPUT_POLICY="*\([A-Za-z]*\)"*/\1/p' /etc/default/ufw 2>/dev/null | tr 'A-Z' 'a-z') || true
    case "$d" in drop) d=deny ;; accept) d=allow ;; reject) d=reject ;; esac
  fi
  echo "${d:-unknown}"
}

# --- which port is SSH on ----------------------------------------------------

# Ubuntu 22.10+ can run sshd from a SOCKET. When it does, ssh.socket owns the
# listening port and sshd_config's Port is ignored completely, so reading only
# sshd_config (or assuming 22) is how people allow the wrong port and lock
# themselves out with a rule that looks correct.
socket_mode() { systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-enabled ssh.socket >/dev/null 2>&1; }

# The port carrying THIS shell. SSH_CONNECTION would answer instantly, but sudo
# wipes it from the environment, so walk up the process tree to the sshd that
# owns us and ask ss for that connection's local port. This is the one port that
# absolutely must survive: closing it drops the session that is doing the work.
session_port() {
  local p=$$ comm ppid
  while [ "$p" -gt 1 ]; do
    comm=$(cat "/proc/$p/comm" 2>/dev/null) || true
    [ -z "$comm" ] && return 0
    case "$comm" in
      sshd|sshd-session|sshd*)
        ss -Htnp 2>/dev/null | grep "pid=$p," | awk '{print $4}' | sed 's/.*://' | head -1
        return 0 ;;
    esac
    # /proc/PID/stat's second field is the command name in parentheses and may
    # contain spaces, which shifts every later field; /proc/PID/status is safe.
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null) || true
    [ -z "$ppid" ] && return 0
    p="$ppid"
  done
}

# Union of every source, because any single one of them can be stale: the unit
# file, the effective sshd config, what is really listening, and our own socket.
ssh_ports() {
  local out=""
  if socket_mode; then
    out=$(systemctl cat ssh.socket 2>/dev/null | sed -n 's/^ListenStream=//p' | sed 's/.*://') || true
  fi
  if command -v sshd >/dev/null 2>&1; then
    out="$out
$(sshd -T 2>/dev/null | awk 'tolower($1)=="port"{print $2}')"
  fi
  out="$out
$(ss -lntpH 2>/dev/null | grep -E 'sshd' | awk '{print $4}' | sed 's/.*://')"
  out="$out
$SESS_PORT"
  echo "$out" | grep -E '^[0-9]+$' | sort -un
}

# --- reading ufw's own rule set ---------------------------------------------

# Source of truth is `ufw show added`, NOT `ufw status`: while the firewall is
# inactive `ufw status` prints nothing but "Status: inactive" and the rules you
# already added are invisible - which is exactly the moment the pre-enable SSH
# check needs to see them.
# Emits one rule per line as: action <TAB> proto <TAB> target
fw_rules() {
  local line rest action proto tgt
  ufw show added 2>/dev/null | sed -n 's/^ufw //p' | while IFS= read -r line; do
    case "$line" in
      "allow "*) action=allow; rest=${line#allow } ;;
      "limit "*) action=allow; rest=${line#limit } ;;
      "deny "*)  action=deny;  rest=${line#deny } ;;
      "reject "*) action=deny; rest=${line#reject } ;;
      *) continue ;;
    esac
    proto=any
    case " $rest " in
      *" proto tcp "*) proto=tcp ;;
      *" proto udp "*) proto=udp ;;
    esac
    if [ "${rest#*" port "}" != "$rest" ]; then
      tgt=${rest#*" port "}; tgt=${tgt%% *}
    else
      case "$rest" in
        # A source-only rule ("allow from 10.0.0.5") opens every port from that
        # host, so it does technically cover SSH. We deliberately do NOT count
        # it: treating it as "SSH is allowed" and being wrong strands the
        # operator, while ignoring it only costs one extra explicit rule.
        "from "*|"proto "*|"in "*|"out "*|"on "*) continue ;;
        *) tgt=$rest ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$action" "$proto" "$tgt"
  done
}

# Turn each rule target into concrete "port proto action" lines: numbers stay,
# comma lists split, ranges stay as lo:hi, and names are resolved by asking ufw
# (application profiles) or /etc/services rather than guessing that OpenSSH
# means 22 - on a box with a changed port that guess is exactly backwards.
expand_rules() {
  local line action proto tgt ports p pp pr base item
  for line in "${FW_RULES[@]}"; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r action proto tgt <<< "$line"
    [ -n "$tgt" ] || continue
    # Split any protocol suffix off FIRST. Testing the whole target for
    # "contains a letter" would send "2222/tcp" down the profile-name path and
    # silently drop the rule - which reads as "SSH is not allowed" and refuses
    # a perfectly safe enable.
    pr="$proto"; base="$tgt"
    case "$tgt" in */*) pr=${tgt##*/}; base=${tgt%%/*} ;; esac
    case "$base" in
      *[!0-9,:]*)
        ports=$(ufw app info "$base" 2>/dev/null | awk '/^Ports?:/{f=1; sub(/^Ports?:[ \t]*/,""); if (NF) print; next} f&&NF{print}' | tr ',' ' ') || true
        if [ -z "$ports" ]; then
          ports=$(getent services "$base" 2>/dev/null | awk '{print $2}') || true
        fi
        for p in $ports; do
          pp=${p%%/*}
          if [ "${p#*/}" = "$p" ]; then item="$pr"; else item=${p##*/}; fi
          printf '%s %s %s\n' "$pp" "$item" "$action"
        done
        ;;
      *)
        base=${base//,/ }
        for item in $base; do printf '%s %s %s\n' "$item" "$pr" "$action"; done
        ;;
    esac
  done
}

load_rules() {
  mapfile -t FW_RULES < <(fw_rules)
  mapfile -t FW_PORTS < <(expand_rules)
}

# Does an allow rule cover this port/proto? Ranges count, "any" proto counts.
port_allowed() {
  local want="$1" wproto="$2" pair port proto action lo hi
  for pair in "${FW_PORTS[@]}"; do
    [ -n "$pair" ] || continue
    read -r port proto action <<< "$pair"
    [ "$action" = "allow" ] || continue
    if [ "$proto" != "any" ] && [ "$proto" != "$wproto" ]; then continue; fi
    case "$port" in
      *:*) lo=${port%%:*}; hi=${port##*:}
           if [ "$lo" -le "$want" ] 2>/dev/null && [ "$hi" -ge "$want" ] 2>/dev/null; then return 0; fi ;;
      *)   if [ "$port" = "$want" ]; then return 0; fi ;;
    esac
  done
  return 1
}

# ufw takes the FIRST matching rule, so a deny sitting above an allow wins. We
# do not try to model rule order; we just refuse to pretend a port is safe when
# a deny for it exists anywhere in the set.
port_denied() {
  local want="$1" pair port proto action
  for pair in "${FW_PORTS[@]}"; do
    [ -n "$pair" ] || continue
    read -r port proto action <<< "$pair"
    [ "$action" = "deny" ] || continue
    if [ "$port" = "$want" ]; then return 0; fi
  done
  return 1
}

# --- what is actually listening ---------------------------------------------

# One row per protocol+port: "proto port scope process". A service bound only to
# loopback can never be reached from outside no matter what the firewall says,
# so it is marked and excluded from the mismatch report; 0.0.0.0 and [::] on the
# same port are folded into one row so the table stays readable.
listen_rows() {
  ss -lntupH 2>/dev/null | awk '
    {
      l=$5
      port=l; sub(/.*:/,"",port)
      addr=l; sub(/:[^:]*$/,"",addr)
      scope=(addr ~ /^127\./ || addr=="[::1]" || addr=="::1") ? "local" : "all"
      name=""
      if (match($0, /\(\("[^"]+"/)) name=substr($0, RSTART+3, RLENGTH-4)
      k=$1":"port
      if (!(k in S) || scope=="all") S[k]=scope
      if (name!="") N[k]=name
      T[k]=$1; P[k]=port
    }
    END { for (k in S) printf "%s %s %s %s\n", T[k], P[k], S[k], (k in N ? N[k] : "-") }
  ' | sort -k1,1 -k2,2n
}

# Ports the firewall opens that no process answers on. Ranges are skipped rather
# than expanded - a range of 8000 ports would bury the report.
unserved() {
  local pair port proto action
  for pair in "${FW_PORTS[@]}"; do
    [ -n "$pair" ] || continue
    read -r port proto action <<< "$pair"
    [ "$action" = "allow" ] || continue
    case "$port" in *[!0-9]*) continue ;; esac
    if ! echo "$LISTEN" | awk -v p="$port" -v pr="$proto" \
         '$2==p && (pr=="any" || $1==pr){f=1} END{exit !f}'; then
      echo "  $port/$proto"
    fi
  done | sort -u
}

# --- display -----------------------------------------------------------------

show() {
  local st fdst logging v6 boot
  if ufw_active; then st="active"; else st="inactive (nothing is being filtered)"; fi
  fdst=$(svc_state firewalld)
  command -v firewall-cmd >/dev/null 2>&1 || fdst="not installed"
  logging=$(ufw status verbose 2>/dev/null | sed -n 's/^Logging: //p') || true
  # IPV6 lives in /etc/default/ufw; ENABLED (start-on-boot) lives in
  # /etc/ufw/ufw.conf. Reading either from the other file quietly prints
  # "unknown" forever.
  v6=$(sed -n 's/^IPV6=//p' /etc/default/ufw 2>/dev/null | tr -d '"') || true
  boot=$(sed -n 's/^ENABLED=//p' /etc/ufw/ufw.conf 2>/dev/null | tr -d '"') || true
  if [ -z "$logging" ]; then
    logging=$(sed -n 's/^LOGLEVEL=//p' /etc/ufw/ufw.conf 2>/dev/null | tr -d '"') || true
    if [ -n "$logging" ]; then logging="$logging (configured, not running)"; fi
  fi

  echo
  echo "Firewall state"
  echo "----------------------------------------------------------------------"
  printf "  %-22s %s\n" "ufw:" "$st"
  printf "  %-22s %s\n" "default incoming:" "$(default_incoming)"
  printf "  %-22s %s\n" "starts at boot:" "${boot:-unknown}"
  printf "  %-22s %s\n" "IPv6 rules:" "${v6:-unknown}"
  printf "  %-22s %s\n" "logging:" "${logging:-(off / unknown)}"
  printf "  %-22s %s\n" "firewalld:" "$fdst"
  printf "  %-22s %s\n" "SSH port(s) detected:" "${SSH_PORTS:-none found}"
  if [ -n "$SESS_PORT" ]; then
    printf "  %-22s %s\n" "this session is on:" "port $SESS_PORT (do not close it)"
  else
    printf "  %-22s %s\n" "this session is on:" "console / not SSH"
  fi
  if command -v docker >/dev/null 2>&1; then
    printf "  %-22s %s\n" "docker:" "installed - published container ports BYPASS ufw"
  fi
  echo "----------------------------------------------------------------------"

  echo
  if ufw_active; then
    echo "Rules (numbered, as ufw is enforcing them):"
    list_rules
  else
    echo "Rules added so far (not being enforced - ufw is off):"
    if [ "${#FW_RULES[@]}" -eq 0 ]; then
      echo "  (none)"
    else
      ufw show added 2>/dev/null | sed -n 's/^ufw /  ufw /p'
    fi
  fi

  echo
  echo "Listening sockets vs the firewall:"
  printf "  %-5s %-7s %-9s %-16s %s\n" "PROTO" "PORT" "BOUND" "PROCESS" "FIREWALL"
  local proto port scope name verdict
  while read -r proto port scope name; do
    [ -n "$proto" ] || continue
    if [ "$scope" = "local" ]; then
      verdict="n/a (loopback only)"
    elif ! ufw_active; then
      verdict="- (ufw off)"
    elif port_allowed "$port" "$proto"; then
      verdict="allowed"
    else
      verdict="BLOCKED"
    fi
    printf "  %-5s %-7s %-9s %-16s %s\n" "$proto" "$port" "$scope" "$name" "$verdict"
  done <<< "$LISTEN"

  echo
  local u
  u=$(unserved) || true
  if [ -n "$u" ]; then
    echo "Open in the firewall, but nothing is listening (rules you can probably drop):"
    echo "$u"
  else
    echo "Every allowed port has something listening on it."
  fi

  # The loudest thing on the screen, because it is the one that ends careers.
  if ufw_active && [ -n "$SESS_PORT" ] && ! port_allowed "$SESS_PORT" tcp; then
    echo
    echo "!! WARNING: the firewall is ON and has NO rule for port $SESS_PORT, the port"
    echo "!! carrying this session. It survives only because it was already established."
    echo "!! Add the rule (menu 3) BEFORE you disconnect, or you will not get back in."
  fi
  echo
}

# --- guards and plumbing -----------------------------------------------------

# Two firewalls writing the same netfilter tables is not a merge, it is a race:
# whichever reloads last owns the chains, and reboot order decides your security
# policy. So we manage ufw only when firewalld is not the one in charge.
guard_other_firewall() {
  if firewalld_active; then
    echo
    echo "REFUSING: firewalld is the ACTIVE firewall on this machine."
    echo "ufw and firewalld both drive netfilter directly and will overwrite each"
    echo "other's chains, so this wizard will not touch anything. Choose one:"
    echo "  keep firewalld  ->  manage rules with firewall-cmd, not this tool"
    echo "  switch to ufw   ->  systemctl disable --now firewalld   then re-run"
    echo
    return 1
  fi
  return 0
}

backup() {
  local ts bk
  ts=$(date +%Y%m%d-%H%M%S)
  bk="$BKDIR/$ts"
  mkdir -p "$bk"
  cp -a /etc/ufw/*.rules "$bk"/ 2>/dev/null || true
  cp -a /etc/ufw/ufw.conf /etc/default/ufw "$bk"/ 2>/dev/null || true
  ufw show added > "$bk/added-rules.txt" 2>/dev/null || true
  echo "  backup taken: $bk"
}

# Validate every rule with `ufw --dry-run` first and apply nothing if any one of
# them is rejected. Half-applied rule sets are how a box ends up open on one
# port and closed on the one you needed.
apply_rules() {
  local r out
  for r in "$@"; do
    if ! out=$(ufw --dry-run $r 2>&1); then
      echo
      echo "REFUSING TO APPLY - ufw rejected:  ufw $r"
      echo "$out" | sed 's/^/    /'
      return 1
    fi
  done
  backup
  for r in "$@"; do
    if ufw $r >/dev/null 2>&1; then
      echo "  applied: ufw $r"
    else
      echo "  FAILED : ufw $r"
    fi
  done
  load_rules
  return 0
}

# `ufw ... | grep | sed` succeeds even when grep matched nothing, because the
# pipeline's status is sed's - so `|| echo "(none)"` would never fire. Capture
# first, then test the variable.
list_rules() {
  local out
  out=$(ufw status numbered 2>/dev/null | grep -E '^\[' | sed 's/^/  /') || true
  echo "${out:-  (no rules)}"
}

covers_ssh() {
  local tok="$1" base p
  base=${tok%%/*}
  case "$base" in OpenSSH|ssh|SSH) return 0 ;; esac
  for p in $SSH_PORTS; do
    if [ "$base" = "$p" ]; then return 0; fi
  done
  return 1
}

# --- actions -----------------------------------------------------------------

enable_fw() {
  guard_other_firewall || return 0
  local ans

  if ufw_active; then
    echo
    echo "The firewall is ON. Turning it off leaves every listening port above"
    echo "reachable from anywhere the network can get to."
    read -rp "  Type 'off' to disable it, Enter to leave it on: " ans || true
    if [ "$ans" = "off" ]; then
      backup
      ufw disable >/dev/null
      echo "  Firewall disabled. Nothing is being filtered now."
    else
      echo "  Left on."
    fi
    return 0
  fi

  local p missing="" allowed_any=0
  for p in $SSH_PORTS; do
    if port_allowed "$p" tcp; then allowed_any=1; else missing="$missing $p"; fi
  done

  echo
  if [ "$(default_incoming)" = "allow" ]; then
    echo "NOTE: the default policy for incoming traffic is ALLOW, so enabling ufw"
    echo "      will not close anything - only your explicit deny rules apply."
    allowed_any=1
    missing=""
  fi

  if [ -z "$SSH_PORTS" ]; then
    # No sshd and no ssh session: the operator is on a console, so enabling
    # cannot strand them. Still confirm, because a headless box with a broken
    # sshd is a box you reach only with a KVM.
    echo "No SSH server and no SSH session were detected on this machine."
    echo "If you are on a physical/KVM console this is safe. If you are remote by"
    echo "some other means, check it survives a closed firewall first."
    read -rp "  Enable the firewall anyway? (yes/no) [no]: " ans || true
    [ "$ans" = "yes" ] || { echo "  Cancelled."; return 0; }
  else
    if [ -n "$SESS_PORT" ] && port_denied "$SESS_PORT"; then
      echo "REFUSING: there is a DENY rule for port $SESS_PORT, the port this session"
      echo "is on. ufw applies the first matching rule, so that deny may win over any"
      echo "allow you add. Delete it with menu option 4, then enable."
      return 0
    fi
    local must_have=0
    if [ -n "$SESS_PORT" ] && ! port_allowed "$SESS_PORT" tcp; then must_have=1; fi
    if [ "$allowed_any" -eq 0 ] || [ "$must_have" -eq 1 ]; then
      echo "REFUSING to enable the firewall yet."
      echo
      echo "ufw has no allow rule for SSH on port(s):${missing:- $SESS_PORT}"
      echo "Default incoming policy is $(default_incoming), so enabling now would drop"
      echo "the next SSH connection to this box. If you are reading this over SSH,"
      echo "your way back in would be a console or KVM - and often that is nothing."
      echo
      echo "  1) add 'allow <port>/tcp' for the port(s) above, then enable"
      echo "  2) cancel and change nothing"
      read -rp "  Choice [2]: " ans || true
      [ "$ans" = "1" ] || { echo "  Cancelled - the firewall is still off."; return 0; }
      local cmds=()
      for p in ${missing:-$SESS_PORT}; do cmds+=("allow $p/tcp"); done
      apply_rules "${cmds[@]}" || return 0
      for p in ${missing:-$SESS_PORT}; do
        if ! port_allowed "$p" tcp; then
          echo "  REFUSING: port $p still is not allowed after adding the rule."
          return 0
        fi
      done
    fi
    echo "SSH is allowed on:${SSH_PORTS:+ $SSH_PORTS}"
  fi

  # Enabling a bare firewall on a SAMM box silently cuts off every MikroTik NAS
  # authenticating against it: SSH is allowed, RADIUS is not, and nothing in the
  # panel says why subscribers stopped connecting. Say so BEFORE they type yes.
  if [ -d /opt/samm ] || systemctl list-units --no-legend --plain "samm-*" 2>/dev/null | grep -q .; then
    if ! ufw status 2>/dev/null | grep -q "1812"; then
      echo
      echo "  NOTE: this box runs SAMM, and there is no rule for RADIUS (1812/1813) yet."
      echo "  Enabling now keeps YOU connected over SSH but drops every NAS that"
      echo "  authenticates here, and the panel will not tell you that is why."
      echo "  Run preset 1 (SAMM) first, or add the ports yourself."
      echo
    fi
  fi
  read -rp "  Enable the firewall now? (yes/no) [no]: " ans || true
  [ "$ans" = "yes" ] || { echo "  Cancelled."; return 0; }
  backup
  # `ufw enable` asks its own "may disrupt existing ssh connections" question and
  # would hang here waiting for an answer we already collected.
  ufw --force enable >/dev/null
  load_rules
  echo "  Firewall is ON."
  echo
  echo "  Before you close this session: open a SECOND ssh connection to this box"
  echo "  and confirm it works. An established session keeps working even when the"
  echo "  rule for its port is wrong, so this session proves nothing by itself."
}

edit_rule() {
  guard_other_firewall || return 0
  local act port proto protos src ans isapp=0 cmds=()

  echo
  read -rp "  1) allow    2) deny    [1]: " ans || true
  case "$ans" in ""|1) act=allow ;; 2) act=deny ;; *) echo "  Not a choice."; return 0 ;; esac

  echo "  Port number (e.g. 8000), a range (6000:6010), or an app profile name."
  # Profile names can contain spaces ("Nginx Full"), so squeeze the indent and
  # join with commas rather than deleting spaces and inventing "NginxFull".
  local profiles
  profiles=$(ufw app list 2>/dev/null | tail -n +2 | sed 's/^ *//;/^$/d' | paste -sd'|' - | sed 's/|/, /g') || true
  echo "  Profiles ufw knows: ${profiles:-(none)}"
  read -rp "  Port or profile (Enter = cancel): " port || true
  [ -z "$port" ] && { echo "  Cancelled."; return 0; }

  if echo "$port" | grep -qE '^[0-9]+$'; then
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      echo "  $port is not a valid port number."; return 0
    fi
  elif echo "$port" | grep -qE '^[0-9]+:[0-9]+$'; then
    :
  else
    if ! ufw app info "$port" >/dev/null 2>&1; then
      echo "  No application profile called '$port'. Check 'ufw app list'."; return 0
    fi
    isapp=1
  fi

  # Refuse to hand the operator the gun. A deny on the SSH port takes effect on
  # the NEXT connection, which is the one that was going to fix it.
  if [ "$act" = "deny" ] && [ "$isapp" -eq 0 ] && covers_ssh "$port"; then
    echo
    echo "REFUSING: port $port is an SSH port on this machine (SSH: $SSH_PORTS)."
    echo "Denying it would close the door behind you on your next login. If you"
    echo "really mean to move SSH, change the port first and verify it, then deny."
    return 0
  fi

  if [ "$isapp" -eq 1 ]; then
    protos=""   # the profile carries its own protocols
  else
    read -rp "  Protocol: 1) tcp   2) udp   3) both   [1]: " ans || true
    case "$ans" in ""|1) protos="tcp" ;; 2) protos="udp" ;; 3) protos="tcp udp" ;; *) echo "  Not a choice."; return 0 ;; esac
  fi

  echo "  Restrict to a source? e.g. 10.0.0.0/8 or 203.0.113.7 - Enter for anywhere."
  read -rp "  Source (Enter = anywhere): " src || true
  if [ -n "$src" ] && ! echo "$src" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$|^[0-9a-fA-F:]+(/[0-9]{1,3})?$'; then
    echo "  '$src' does not look like an address or CIDR."; return 0
  fi

  if [ "$isapp" -eq 1 ]; then
    if [ -n "$src" ]; then cmds=("$act from $src to any app $port"); else cmds=("$act $port"); fi
  else
    for proto in $protos; do
      if [ -n "$src" ]; then
        cmds+=("$act from $src to any port $port proto $proto")
      else
        cmds+=("$act $port/$proto")
      fi
    done
  fi

  echo
  echo "  About to run:"
  for ans in "${cmds[@]}"; do echo "    ufw $ans"; done
  read -rp "  Proceed? (yes/no) [no]: " ans || true
  [ "$ans" = "yes" ] || { echo "  Cancelled."; return 0; }
  apply_rules "${cmds[@]}" || return 0
  if ufw_active; then list_rules; fi
}

del_rule() {
  guard_other_firewall || return 0
  local n line tok ans

  if ! ufw_active; then
    # Numbers only exist for the running rule set; while ufw is off the rules
    # can still be removed, but only by repeating them exactly.
    echo
    echo "ufw is off, so there is no numbered rule list. Rules on file:"
    ufw show added 2>/dev/null | sed -n 's/^ufw /  ufw /p'
    echo
    echo "Remove one by repeating it with 'delete', e.g.:  ufw delete allow 80/tcp"
    return 0
  fi

  echo
  list_rules
  echo
  read -rp "  Rule number to delete (Enter = cancel): " n || true
  [ -z "$n" ] && { echo "  Cancelled."; return 0; }
  if ! echo "$n" | grep -qE '^[0-9]+$'; then echo "  '$n' is not a number."; return 0; fi
  line=$(ufw status numbered | grep -E "^\[ *$n\]" | head -1) || true
  if [ -z "$line" ]; then echo "  There is no rule $n."; return 0; fi

  echo "  Rule $n: $line"
  tok=$(echo "$line" | sed 's/^\[[^]]*\][[:space:]]*//' | awk '{print $1}')
  if covers_ssh "$tok"; then
    echo
    echo "  This rule is what lets SSH in (SSH port(s): $SSH_PORTS). Deleting it"
    echo "  while the firewall is on means the next login attempt is refused; this"
    echo "  session survives only until you close it."
    read -rp "  Type YES in capitals to delete it anyway: " ans || true
    [ "$ans" = "YES" ] || { echo "  Cancelled."; return 0; }
  else
    read -rp "  Delete it? (yes/no) [no]: " ans || true
    [ "$ans" = "yes" ] || { echo "  Cancelled."; return 0; }
  fi
  backup
  ufw --force delete "$n" >/dev/null
  load_rules
  echo "  Deleted. Remaining rules:"
  list_rules
}

presets() {
  guard_other_firewall || return 0
  local ans p sshonly=0 cmds=()
  echo
  echo "  1) SAMM      adds: 1812/udp and 1813/udp (RADIUS auth + accounting),"
  echo "               8000/tcp (SAMM API/admin), 80, 81 and 443/tcp (portals)."
  echo "               Adds only - closes nothing that is open today."
  echo "  2) Web       adds: 80/tcp and 443/tcp. Nothing else changes."
  echo "  3) SSH only  allows SSH on port(s) [${SSH_PORTS:-unknown}], sets the"
  echo "               default for incoming traffic to DENY, and then offers -"
  echo "               separately, and only if you type WIPE - to delete every"
  echo "               other allow rule."
  read -rp "  Choice (Enter = cancel): " ans || true
  case "$ans" in
    # 81/tcp belongs here: SAMM's nginx site declares `listen 81 default_server`
    # next to 80, so a preset that opens only 80 leaves half the panel firewalled
    # off on every standard install. Verified on a stock 4.1.14 box.
    1) cmds=("allow 1812/udp" "allow 1813/udp" "allow 8000/tcp" "allow 80/tcp" "allow 81/tcp" "allow 443/tcp") ;;
    2) cmds=("allow 80/tcp" "allow 443/tcp") ;;
    3)
      if [ -z "$SSH_PORTS" ]; then
        echo "  REFUSING: no SSH port could be detected, so 'SSH only' would open"
        echo "  nothing at all and then deny everything. Sort SSH out first."
        return 0
      fi
      sshonly=1
      for p in $SSH_PORTS; do cmds+=("allow $p/tcp"); done
      ;;
    *) echo "  Cancelled."; return 0 ;;
  esac

  echo
  echo "  About to run:"
  for p in "${cmds[@]}"; do echo "    ufw $p"; done
  if [ "$sshonly" -eq 1 ]; then
    echo "    ufw default deny incoming"
    echo "    ufw default allow outgoing"
  fi
  read -rp "  Proceed? (yes/no) [no]: " ans || true
  [ "$ans" = "yes" ] || { echo "  Cancelled."; return 0; }
  apply_rules "${cmds[@]}" || return 0

  [ "$sshonly" -eq 1 ] || return 0

  # The allow rules go in BEFORE the policy flips to deny. The other order is
  # briefly a box with deny-incoming and no SSH rule, which is a lockout if the
  # script dies in between.
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  echo "  default incoming is now deny, outgoing allow"

  # The cleanup half is kept separate so nobody deletes rules just by picking a
  # preset. It needs the numbered list, which exists only while ufw is running,
  # and it deletes from the BOTTOM up: each delete renumbers everything below
  # it, so descending order is the only order that stays correct.
  if ! ufw_active; then
    echo "  (ufw is off, so the other rules cannot be listed by number. Enable it"
    echo "   with option 2, then remove leftovers with option 4.)"
    return 0
  fi
  local nums=() n line tok
  while read -r line; do
    [ -n "$line" ] || continue
    n=$(echo "$line" | sed -n 's/^\[ *\([0-9]*\)\].*/\1/p')
    tok=$(echo "$line" | sed 's/^\[[^]]*\][[:space:]]*//' | awk '{print $1}')
    if [ -n "$n" ] && ! covers_ssh "$tok"; then nums+=("$n"); fi
  done <<< "$(ufw status numbered 2>/dev/null | grep -E '^\[' || true)"
  if [ "${#nums[@]}" -eq 0 ]; then
    echo "  No non-SSH rules are left to remove."
    return 0
  fi
  echo
  echo "  These non-SSH rules are still present:"
  for n in "${nums[@]}"; do ufw status numbered | grep -E "^\[ *$n\]" | sed 's/^/    /'; done
  read -rp "  Type WIPE in capitals to delete all of them: " ans || true
  [ "$ans" = "WIPE" ] || { echo "  Left them in place."; return 0; }
  backup
  for n in $(printf '%s\n' "${nums[@]}" | sort -rn); do
    ufw --force delete "$n" >/dev/null 2>&1 || echo "  could not delete rule $n"
  done
  load_rules
  echo "  Done. Rules now:"
  list_rules
}

reset_fw() {
  guard_other_firewall || return 0
  local ans p
  echo
  echo "Reset to defaults will:"
  echo "  - delete EVERY ufw rule on this machine (this also turns ufw off)"
  echo "  - set default: deny incoming, allow outgoing"
  echo "  - re-add allow <port>/tcp for SSH on: ${SSH_PORTS:-NONE DETECTED}"
  echo "  - leave the firewall OFF until you enable it from the menu"
  if [ -z "$SSH_PORTS" ]; then
    echo
    echo "REFUSING: no SSH port could be detected, so the reset could not re-open"
    echo "one, and a deny-incoming policy with no SSH rule is a locked box. Fix or"
    echo "start SSH first, then reset."
    return 0
  fi
  read -rp "  Type RESET in capitals to continue: " ans || true
  [ "$ans" = "RESET" ] || { echo "  Cancelled."; return 0; }
  backup
  # ufw's own reset also drops a copy of the live rules in /etc/ufw; ours above
  # is the one that keeps the human-readable rule list too.
  ufw --force reset | sed 's/^/  /'
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in $SSH_PORTS; do ufw allow "$p"/tcp >/dev/null; echo "  allowed $p/tcp"; done
  load_rules
  echo "  Reset done. The firewall is OFF - use option 2 to turn it on."
}

# --- start -------------------------------------------------------------------

if ! command -v ufw >/dev/null 2>&1; then
  echo "ufw is not installed on this machine."
  if firewalld_active; then
    guard_other_firewall || true
    exit 0
  fi
  read -rp "Install it now with apt? (yes/no) [no]: " a || true
  if [ "$a" = "yes" ]; then
    export DEBIAN_FRONTEND=noninteractive
    if ! (apt-get update -qq && apt-get install -y ufw); then
      echo "Install failed. Fix apt, then re-run."; exit 1
    fi
    # Installing ufw does not enable it, which is the behaviour we want: no
    # package install should silently start filtering an in-use SSH session.
    echo "Installed. The firewall is still OFF."
  else
    echo "Nothing to do."; exit 0
  fi
fi

SESS_PORT=$(session_port) || true
SSH_PORTS=$(ssh_ports | tr '\n' ' ') || true
SSH_PORTS=$(echo "$SSH_PORTS" | sed 's/ *$//')
LISTEN=$(listen_rows) || true
load_rules

echo
echo "======================================================================"
echo " Firewall wizard (ufw)"
echo "======================================================================"
if firewalld_active; then
  echo
  echo "!! firewalld is ACTIVE on this box. Only 'show status' will run; every"
  echo "!! change is refused so the two firewalls cannot fight over netfilter."
fi
show

echo "   1) Show status again (rules vs what is really listening)"
echo "   2) Turn the firewall on (or off)"
echo "   3) Allow / deny a port or service"
echo "   4) Delete a rule"
echo "   5) Presets (SAMM / web / SSH only)"
echo "   6) Reset to defaults"
echo "  Enter) quit"
read -rp "Choice: " CH || true
case "$CH" in
  1) show ;;
  2) enable_fw ;;
  3) edit_rule ;;
  4) del_rule ;;
  5) presets ;;
  6) reset_fw ;;
  *) echo "Nothing to do." ;;
esac
SCRIPT
chmod +x /usr/local/sbin/fw-wizard
echo "Installed. Run:  sudo fw-wizard"
EOF

sudo fw-wizard