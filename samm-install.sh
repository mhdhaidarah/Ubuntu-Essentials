#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/samm-install <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# ---------------------------------------------------------------------------
# samm-install — install SAMM (SecuryTik Active MikroTik Manager) on this box.
#
# This is a WRAPPER. The real work is done by install.sh inside the release
# tarball; everything here exists to refuse an install that cannot succeed,
# because SAMM's installer changes PostgreSQL, FreeRADIUS, nginx and systemd
# in one pass and a half-finished run leaves all four in a state nobody wants
# to unpick by hand. There is no uninstall script.
# ---------------------------------------------------------------------------

REPO="mhdhaidarah/samm"
API_URL="https://api.github.com/repos/$REPO/releases/latest"
GH_DL="https://github.com/$REPO/releases/download"
# The Cloudflare mirror exists because GitHub is blocked outright in several of
# the countries SAMM is sold into. It carries latest.txt + the tarball + its
# .sha256, so it is a complete fallback, not just a convenience.
MIRROR="https://dl.securytik.com"
WORKDIR="/root"
MIN_RAM_MB=1900          # a "2 GB" VM reports ~1980 MB once firmware is subtracted
MIN_DISK_GB=10           # /opt: compiled bundle + venv + standalone CPython
MIN_WORK_GB=3            # download dir: tarball plus its unpacked copy
MIN_VAR_GB=4             # /var: apt cache, PostgreSQL cluster, journals
INSTALL_LOG="/var/log/samm-install.log"

# Populated by find_latest(); cached so the menu can be walked repeatedly
# without hammering the GitHub API (unauthenticated = 60 requests/hour/IP).
LATEST_VER=""
LATEST_SRC=""
LATEST_SHA=""

PF_FAIL=0
PF_WARN=0

row() { printf "  %-24s %-6s %s\n" "$1" "$2" "$3"; }
ok()   { row "$1" "OK"   "$2"; }
warn() { row "$1" "WARN" "$2"; PF_WARN=$((PF_WARN + 1)); }
bad()  { row "$1" "FAIL" "$2"; PF_FAIL=$((PF_FAIL + 1)); }
rule() { echo "----------------------------------------------------------------------"; }

os_id=""; os_ver=""; os_name=""
if [ -r /etc/os-release ]; then
    # Read the file instead of sourcing it: os-release is shell syntax by
    # convention only, and a vendor-mangled one has sourced arbitrary code into
    # a root script before. Every capture is || true because grep exits 1 when
    # the key is absent and set -e would take that as a fatal error.
    os_id=$(grep -m1 '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"') || true
    os_ver=$(grep -m1 '^VERSION_ID=' /etc/os-release | cut -d= -f2 | tr -d '"') || true
    os_name=$(grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"') || true
fi

# --- small helpers ---------------------------------------------------------

# Who is listening on a port? Prints the holding program name, "?" when we
# cannot look (no ss), or nothing at all when the port is free. Callers MUST
# test the printed value rather than the exit status: a free port is a
# successful lookup that printed nothing, so `x=$(port_holder ...) || echo none`
# would never fire and `[ -z "$x" ]` is the only correct test.
port_holder() {
    local proto="$1" port="$2" line="" prog=""
    if ! command -v ss >/dev/null 2>&1; then
        printf '%s' "?"
        return 0
    fi
    case "$proto" in
        tcp) line=$(ss -Hlntp 2>/dev/null | awk -v p="$port" '{n=split($4,a,":"); if (a[n]==p) print}' | head -1) || true ;;
        udp) line=$(ss -Hlnup 2>/dev/null | awk -v p="$port" '{n=split($4,a,":"); if (a[n]==p) print}' | head -1) || true ;;
    esac
    if [ -z "$line" ]; then
        return 0
    fi
    # ss prints  users:(("sshd",pid=123,fd=3))  — pull out the first quoted
    # program name. Written with an explicit if rather than `A && B` so the
    # busy-port path (the one that matters) cannot trip over exit statuses.
    prog=$(printf '%s' "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p') || true
    printf '%s' "${prog:-unknown}"
    return 0
}

# The mount point that actually holds $1, walking up until the path exists so
# this still answers for /opt on a box where /opt has not been created yet.
mount_of() {
    local p="$1"
    while [ ! -d "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
    df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $6}' || true
}

# Free space in whole GB on the filesystem that holds $1. Resolving to the
# mount point matters: /opt or /var are separate volumes often enough that
# checking only / would pass a box with 400 MB where the venv goes.
free_gb() {
    local p="$1" kb=""
    while [ ! -d "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
    kb=$(df -Pk "$p" 2>/dev/null | awk 'NR==2 {print $4}') || true
    echo $(( ${kb:-0} / 1024 / 1024 ))
}

samm_units() {
    # --no-legend keeps the header and the "N unit files listed" footer out;
    # the glob is passed to systemctl so this stays right if units are added.
    systemctl list-unit-files --no-legend 'samm-*.service' 'samm-*.timer' 2>/dev/null | awk '{print $1}' || true
}

samm_present() {
    local units=""
    units=$(samm_units) || true
    [ -d /opt/samm ] && return 0
    [ -d /etc/samm ] && return 0
    [ -n "$units" ] && return 0
    return 1
}

# --- pre-flight ------------------------------------------------------------

preflight() {
    PF_FAIL=0; PF_WARN=0
    echo
    echo "Pre-flight checks:"
    rule

    # 1. Tooling FIRST, because the port, download and reachability checks
    #    below are meaningless without ss and curl. Everything is best-effort:
    #    on an air-gapped box apt fails and we simply report what is missing.
    local t missing=""
    for t in curl tar sha256sum ss; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        echo "  installing missing tools:$missing"
        apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            curl tar ca-certificates coreutils iproute2 >/dev/null 2>&1 || true
        missing=""
        for t in curl tar sha256sum ss; do
            command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
        done
    fi
    if [ -n "$missing" ]; then
        bad "tooling" "missing:$missing — install them and re-run"
    else
        ok "tooling" "curl, tar, sha256sum, ss present"
    fi

    # 2. Distribution. install.sh is apt-only end to end (packages, FreeRADIUS
    #    layout, nginx sites-enabled); on anything else it fails part-way, not
    #    at the start, which is the worst possible moment.
    case "$os_id" in
        ubuntu)
            local n=""
            n=$(printf '%s' "$os_ver" | awk -F. '{printf "%d%02d", $1, $2}') || true
            if [ -z "$n" ]; then warn "operating system" "Ubuntu, version unknown"
            elif [ "$n" -lt 2004 ]; then bad "operating system" "$os_name — 20.04 is the oldest supported"
            elif [ "$n" -gt 2404 ]; then warn "operating system" "$os_name — newer than tested (24.04)"
            else ok "operating system" "$os_name"; fi ;;
        debian)
            local d=""
            d=$(printf '%s' "$os_ver" | cut -d. -f1) || true
            if ! printf '%s' "$d" | grep -qE '^[0-9]+$'; then warn "operating system" "Debian testing/sid — untested"
            elif [ "$d" -lt 11 ]; then bad "operating system" "$os_name — Debian 11 is the oldest supported"
            else ok "operating system" "$os_name"; fi ;;
        *)
            bad "operating system" "${os_name:-unknown} — Ubuntu/Debian only (apt)" ;;
    esac

    # 3. Architecture. The bare-OS tarball ships Cython .so modules compiled
    #    for x86-64 and ONLY that CPU can import them — on arm64 the install
    #    completes and every service then dies on ImportError. arm64 users are
    #    served by the multi-arch container images instead.
    local arch=""
    arch=$(uname -m) || true
    case "$arch" in
        x86_64|amd64) ok "architecture" "$arch" ;;
        aarch64|arm64) bad "architecture" "$arch — the tarball is x86-64 only; use the Docker bundle" ;;
        *) bad "architecture" "${arch:-unknown} — unsupported" ;;
    esac

    # 4. Init system. Every SAMM daemon ships as a systemd unit; there is no
    #    sysvinit or supervisord path in the installer.
    local init=""
    init=$(ps -p 1 -o comm= 2>/dev/null) || true
    if [ "$init" = "systemd" ]; then ok "init system" "systemd"
    else bad "init system" "${init:-unknown} — systemd required"; fi

    # 5. Memory. PostgreSQL + FreeRADIUS + the FastAPI workers do not fit in
    #    1 GB, and the Cython import cost at boot makes a swapless 1 GB box
    #    OOM during the first start rather than at install time.
    local mem_mb="" swap_mb=""
    mem_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo) || true
    swap_mb=$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo) || true
    if [ "${mem_mb:-0}" -lt "$MIN_RAM_MB" ]; then
        bad "memory" "${mem_mb:-?} MB — 2 GB minimum"
    elif [ "${mem_mb:-0}" -lt 2600 ] && [ "${swap_mb:-0}" -lt 256 ]; then
        warn "memory" "${mem_mb} MB and no swap — add 1 GB of swap first"
    else
        ok "memory" "${mem_mb:-?} MB (swap ${swap_mb:-0} MB)"
    fi

    # 6. Disk, per tree, with the amount each tree actually needs rather than
    #    one blanket number: demanding 10 GB of a separate 5 GB /var would
    #    refuse a box that is perfectly able to run SAMM. Mount points already
    #    reported are skipped so a single-filesystem box shows one row.
    local seen=" " spec p need label m g
    for spec in "/opt:$MIN_DISK_GB:app, venv, CPython" "$WORKDIR:$MIN_WORK_GB:tarball + unpacked tree" "/var:$MIN_VAR_GB:apt, PostgreSQL, logs"; do
        p="${spec%%:*}"
        need="${spec#*:}"; need="${need%%:*}"
        label="${spec##*:}"
        m=$(mount_of "$p") || true
        [ -z "$m" ] && continue
        case "$seen" in *" $m "*) continue ;; esac
        seen="$seen$m "
        g=$(free_gb "$p") || true
        if [ "${g:-0}" -lt "$need" ]; then bad "free space $m" "${g:-?} GB — ${need} GB needed ($label)"
        else ok "free space $m" "${g} GB free ($label)"; fi
    done

    # 7. Ports. 8000 is the FastAPI backend nginx proxies to; 1812/1813 are the
    #    RADIUS auth/accounting sockets. All three are hard-coded in the
    #    generated configs, so a squatter is a broken install, not a retry.
    local holder=""
    holder=$(port_holder tcp 8000) || true
    if [ -z "$holder" ]; then ok "port 8000/tcp" "free (SAMM API)"
    elif [ "$holder" = "?" ]; then warn "port 8000/tcp" "cannot check — iproute2 (ss) not installed"
    else bad "port 8000/tcp" "in use by '$holder' — SAMM needs it"; fi
    local rport=""
    for rport in 1812 1813; do
        holder=$(port_holder udp "$rport") || true
        if [ -z "$holder" ]; then ok "port $rport/udp" "free (RADIUS)"
        elif [ "$holder" = "?" ]; then warn "port $rport/udp" "cannot check — iproute2 (ss) not installed"
        else bad "port $rport/udp" "in use by '$holder' — stop it or remove that RADIUS server"; fi
    done
    # Port 80 is deliberately NOT a failure: the installer detects a busy :80,
    # leaves the existing site alone and asks for an alternative port instead.
    holder=$(port_holder tcp 80) || true
    if [ -n "$holder" ] && [ "$holder" != "?" ]; then
        warn "port 80/tcp" "held by '$holder' — installer will ask for another port"
    fi

    # 8. Clock. A skewed clock fails TLS certificate validation, and the curl
    #    error that follows reads like a network outage, sending people to
    #    debug their firewall for an hour.
    local yr=""
    yr=$(date +%Y) || true
    if [ "${yr:-0}" -lt 2024 ]; then bad "system clock" "reads $(date) — fix NTP first, TLS will fail"
    else ok "system clock" "$(date '+%Y-%m-%d %H:%M %Z')"; fi

    # 9. Outbound reachability, tested against the exact hosts we will use.
    local net=""
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS -m 15 -o /dev/null "$API_URL" 2>/dev/null; then net="github"
        elif curl -fsS -m 15 -o /dev/null "$MIRROR/latest.txt" 2>/dev/null; then net="mirror"
        fi
    fi
    case "$net" in
        github) ok "internet" "api.github.com reachable" ;;
        mirror) warn "internet" "GitHub unreachable — will install from $MIRROR" ;;
        *)      bad "internet" "no HTTPS to GitHub or $MIRROR (DNS? proxy? firewall?)" ;;
    esac

    # 10. Existing install. Refuse rather than run the installer over it: this
    #     wizard always fetches the LATEST release, so "installing" on top of a
    #     working box is an unrequested upgrade of a live billing system.
    #     Built with explicit ifs, not `test && assign`: a failing test as the
    #     last statement of a branch is exactly how set -e kills a script.
    if samm_present; then
        local where="" units=""
        units=$(samm_units) || true
        if [ -d /opt/samm ]; then where="/opt/samm"; fi
        if [ -d /etc/samm ]; then where="${where:+$where }/etc/samm"; fi
        if [ -n "$units" ]; then where="${where:+$where }systemd units"; fi
        bad "existing SAMM" "found: ${where:-traces} — update it, do not install over it"
    else
        ok "existing SAMM" "none — clean box"
    fi

    # 11. Container hint. LXC works; Docker/podman does not, because there is
    #     no systemd inside and FreeRADIUS needs its own privileged sockets.
    #     systemd-detect-virt EXITS NON-ZERO when it finds nothing while still
    #     printing "none", so capture with || true and judge the string.
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt -c 2>/dev/null) || true
    fi
    case "$virt" in
        ""|none) : ;;
        lxc|lxc-libvirt|systemd-nspawn) warn "virtualisation" "$virt container — usually fine, watch for missing kernel modules" ;;
        *) warn "virtualisation" "$virt container — SAMM expects a full VM or bare metal" ;;
    esac

    rule
    if [ "$PF_FAIL" -gt 0 ]; then
        printf "  %d blocking problem(s), %d warning(s). Install refused.\n" "$PF_FAIL" "$PF_WARN"
        return 1
    fi
    printf "  All blocking checks passed (%d warning(s)).\n" "$PF_WARN"
    return 0
}

# --- release discovery -----------------------------------------------------

# Best-effort digest lookup for a version. A missing .sha256 is a 404, not a
# reason to abort, so every fetch is guarded; the first 64-hex answer wins.
fetch_sha() {
    local v="$1" out=""
    out=$(curl -fsS -m 20 "$GH_DL/v$v/samm-$v.tar.gz.sha256" 2>/dev/null | grep -m1 -oE '[0-9a-f]{64}') || true
    if [ -z "$out" ]; then
        out=$(curl -fsS -m 20 "$MIRROR/samm-$v.tar.gz.sha256" 2>/dev/null | grep -m1 -oE '[0-9a-f]{64}') || true
    fi
    printf '%s' "$out"
}

find_latest() {
    if [ -n "$LATEST_VER" ]; then
        return 0
    fi
    local json="" v="" sha=""

    json=$(curl -fsS -m 25 "$API_URL" 2>/dev/null) || true
    if [ -n "$json" ]; then
        # Tags are published as v<version>; strip the v so it matches the
        # tarball name samm-<version>.tar.gz.
        v=$(printf '%s' "$json" | grep -m1 -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/') || true
        v="${v#v}"
        # The publisher writes the digest into the release notes as
        # "sha256: `<64 hex>`" — anchor on that text so we can never pick up
        # some other hex blob that happens to live in the JSON.
        sha=$(printf '%s' "$json" | grep -m1 -oE 'sha256: .?[0-9a-f]{64}' | grep -oE '[0-9a-f]{64}') || true
        if [ -n "$v" ]; then
            LATEST_VER="$v"; LATEST_SRC="github"; LATEST_SHA="$sha"
        fi
    fi

    if [ -z "$LATEST_VER" ]; then
        v=$(curl -fsS -m 25 "$MIRROR/latest.txt" 2>/dev/null | tr -d ' \t\r\n') || true
        if [ -n "$v" ]; then
            LATEST_VER="$v"; LATEST_SRC="mirror"; LATEST_SHA=""
        fi
    fi

    if [ -z "$LATEST_VER" ]; then
        echo "Could not determine the latest release (GitHub API and mirror both failed)."
        return 1
    fi

    # The version string is pasted straight into a URL and a filesystem path.
    # Anything that is not a plain version is treated as a failed lookup —
    # this is the one place a hostile or corrupted answer could reach `tar`.
    if ! printf '%s' "$LATEST_VER" | grep -qE '^[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.]+)?$'; then
        echo "Refusing: '$LATEST_VER' does not look like a version number."
        LATEST_VER=""; LATEST_SRC=""; LATEST_SHA=""
        return 1
    fi

    # Release notes are hand-written and the digest is often missing from
    # them; fall back to the published .sha256 files before giving up on
    # verification, because an unverified download is a much worse outcome.
    if [ -z "$LATEST_SHA" ]; then
        LATEST_SHA=$(fetch_sha "$LATEST_VER") || true
    fi
    return 0
}

# --- state display ---------------------------------------------------------

installed_port() {
    # The installer bakes the chosen port into its own vhost; read it back
    # rather than assuming 80, because a box that already had a web server got
    # asked for a different port at install time.
    local p=""
    if [ -f /etc/nginx/sites-available/samm ]; then
        p=$(awk '$1=="listen" && $2 ~ /^[0-9]+;?$/ {gsub(/;/,"",$2); print $2; exit}' /etc/nginx/sites-available/samm) || true
    fi
    echo "${p:-80}"
}

primary_ip() {
    local ip=""
    ip=$(ip -4 -o route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
    echo "${ip:-localhost}"
}

portal_url() {
    local p=""
    p=$(installed_port) || true
    # Only spell out the port when it is not the default, so the common case
    # reads as a plain address someone can retype from a phone photo.
    if [ "${p:-80}" = "80" ]; then echo "http://$(primary_ip)/admin/login"
    else echo "http://$(primary_ip):$p/admin/login"; fi
}

# There is no VERSION file in a real install: version.py is Cython-compiled to
# a .so, so the constant only survives as a string inside the binary. Read the
# source form first (source/dev trees), then probe the compiled module, and
# say "unknown" rather than print something that might be a different number.
installed_version() {
    local v=""
    if [ -r /opt/samm/app/version.py ]; then
        v=$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' /opt/samm/app/version.py) || true
    fi
    if [ -z "$v" ] && command -v strings >/dev/null 2>&1; then
        v=$(strings /opt/samm/app/version.cpython-*.so 2>/dev/null \
            | grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+SAMM_VERSION' | sed 's/SAMM_VERSION//') || true
    fi
    echo "${v:-version unknown}"
}

show() {
    echo
    echo "This machine:"
    rule
    printf "  %-24s %s\n" "OS / arch:" "${os_name:-unknown} / $(uname -m)"
    local mem=""
    mem=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo) || true
    printf "  %-24s %s\n" "memory / free disk:" "${mem:-?} MB / $(free_gb /) GB on $(mount_of /)"
    if samm_present; then
        printf "  %-24s %s\n" "SAMM installed:" "YES ($(installed_version)) — this wizard will not install over it"
        printf "  %-24s %s\n" "admin portal:" "$(portal_url)"
    else
        printf "  %-24s %s\n" "SAMM installed:" "no"
    fi
    rule
}

# --- status report ---------------------------------------------------------

status_report() {
    local units=() u act ena problems=0
    mapfile -t units < <(samm_units)
    if [ "${#units[@]}" -eq 0 ]; then
        echo
        echo "No samm-* units are installed on this machine."
        return 0
    fi
    echo
    echo "SAMM services:"
    rule
    for u in "${units[@]}"; do
        # is-active EXITS NON-ZERO for inactive/failed while still printing the
        # word, so capture with || true and judge the string. Appending
        # "|| echo unknown" here would print two words on one row.
        act=$(systemctl is-active "$u" 2>/dev/null) || true
        ena=$(systemctl is-enabled "$u" 2>/dev/null) || true
        printf "  %-34s %-10s %s\n" "$u" "${act:-unknown}" "${ena:-unknown}"
        case "$u" in
            samm-api.service|samm-radius.service|samm-worker.service)
                # These three must be running for the panel to answer at all.
                if [ "$act" != "active" ]; then problems=$((problems + 1)); fi ;;
            *)
                # Timers and one-shots are legitimately inactive between runs;
                # only an outright failure counts against them.
                if [ "$act" = "failed" ]; then problems=$((problems + 1)); fi ;;
        esac
    done
    for u in freeradius nginx postgresql; do
        act=$(systemctl is-active "$u" 2>/dev/null) || true
        printf "  %-34s %-10s %s\n" "$u.service" "${act:-unknown}" "-"
        if [ "$act" = "failed" ]; then problems=$((problems + 1)); fi
    done
    rule

    if [ "$problems" -gt 0 ]; then
        echo
        echo "  $problems service(s) are NOT healthy. Recent log lines:"
        for u in "${units[@]}" freeradius nginx postgresql; do
            act=$(systemctl is-active "$u" 2>/dev/null) || true
            case "$u" in
                samm-api.service|samm-radius.service|samm-worker.service)
                    if [ "$act" = "active" ]; then continue; fi ;;
                *)
                    if [ "$act" != "failed" ]; then continue; fi ;;
            esac
            echo
            echo "  --- $u (${act:-unknown}) ---"
            journalctl -u "$u" -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || true
        done
        echo
        echo "  Full installer log: $INSTALL_LOG"
        return 1
    fi

    echo
    echo "  Admin portal  : $(portal_url)"
    echo "  First login   : admin / admin   <- CHANGE IT IMMEDIATELY"
    echo "  DB / app creds: /etc/samm/api.env   (config: /etc/samm/samm.yaml)"
    echo "  Installer log : $INSTALL_LOG"
    return 0
}

# --- firewall --------------------------------------------------------------

# Ports sshd is actually listening on, so the lock-out guard below still works
# on a box whose SSH was moved off 22. Falls back to 22 rather than to nothing:
# an empty answer here would mean "no SSH rule needed", which is the dangerous
# direction to be wrong in.
ssh_ports() {
    local p=""
    p=$(ss -Hlntp 2>/dev/null | grep 'sshd' | awk '{n=split($4,a,":"); print a[n]}' | sort -u) || true
    echo "${p:-22}"
}

open_firewall() {
    local port="" fw="none" state="" answer=""
    port=$(installed_port) || true
    if command -v ufw >/dev/null 2>&1; then
        state=$(ufw status 2>/dev/null | head -1) || true
        # "Status: inactive" CONTAINS the word "active". A plain grep for
        # "active" therefore reports every DISABLED ufw as enabled, and this
        # function then went on to write rules on a box that had none. Anchor
        # the whole line instead.
        if printf '%s\n' "$state" | grep -qE '^Status:[[:space:]]+active$'; then fw="ufw"; fi
    fi
    if [ "$fw" = "none" ] && command -v firewall-cmd >/dev/null 2>&1; then
        state=$(systemctl is-active firewalld 2>/dev/null) || true
        if [ "$state" = "active" ]; then fw="firewalld"; fi
    fi

    case "$fw" in
        none)
            echo "No ACTIVE ufw or firewalld — nothing to open."
            echo "If you enable a firewall later, SAMM needs: ${port}/tcp, 1812/udp, 1813/udp."
            return 0 ;;
        ufw)
            echo "ufw is active. Rules to add: ${port}/tcp (panel), 1812/udp + 1813/udp (RADIUS)."
            read -rp "Add the SAMM rules now? [y/N]: " answer || answer=""
            case "$answer" in
                y|Y) ;;
                *) echo "  Left unchanged — no rule was written."; return 0 ;;
            esac
            # Only now, inside the confirmed branch, does anything change.
            # Opening the panel port on a box with no SSH rule is how an
            # operator locks themselves out of a remote machine, so the SSH
            # port is allowed first and the operator is told about it. This
            # wizard never runs `ufw enable` for the same reason: turning a
            # default-deny firewall on from a remote shell ends the session.
            local sp="" rules=""
            rules=$(ufw status 2>/dev/null) || true
            for sp in $(ssh_ports); do
                if ! printf '%s\n' "$rules" | grep -qE "((^|[[:space:]])${sp}(/tcp)?[[:space:]]+ALLOW)|OpenSSH"; then
                    echo "  no ufw rule for SSH port ${sp} — allowing it first so this session survives"
                    ufw allow "${sp}/tcp" >/dev/null 2>&1 || true
                fi
            done
            ufw allow "${port}/tcp" >/dev/null 2>&1 || true
            ufw allow 1812/udp >/dev/null 2>&1 || true
            ufw allow 1813/udp >/dev/null 2>&1 || true
            ufw status numbered 2>/dev/null | sed 's/^/  /' || true ;;
        firewalld)
            echo "firewalld is active. Rules to add: ${port}/tcp, 1812/udp, 1813/udp."
            read -rp "Add the SAMM rules now? [y/N]: " answer || answer=""
            case "$answer" in
                y|Y)
                    # firewalld's default zone almost always has the ssh service
                    # already; add it explicitly anyway rather than assume, for
                    # the same lock-out reason as the ufw branch above.
                    firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
                    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
                    firewall-cmd --permanent --add-port=1812/udp >/dev/null 2>&1 || true
                    firewall-cmd --permanent --add-port=1813/udp >/dev/null 2>&1 || true
                    firewall-cmd --reload >/dev/null 2>&1 || true
                    firewall-cmd --list-ports 2>/dev/null | sed 's/^/  ports: /' || true ;;
                *) echo "  Left unchanged." ;;
            esac ;;
    esac
    return 0
}

# --- install ---------------------------------------------------------------

do_install() {
    if ! preflight; then
        echo
        echo "Fix the FAIL rows above and run samm-install again."
        if samm_present; then
            echo
            echo "This box already has SAMM. To move to a newer version, use the panel's"
            echo "own updater (Admin -> System -> Update) — it stops the services, migrates"
            echo "the database and rolls back on failure. Installing over the top does not."
        fi
        return 1
    fi

    echo
    echo "Looking up the latest release..."
    find_latest || return 1
    local v="$LATEST_VER"
    local tarball="samm-$v.tar.gz"
    local url="" dest="$WORKDIR/$tarball" srcdir="$WORKDIR/samm-$v" answer=""
    if [ "$LATEST_SRC" = "mirror" ]; then url="$MIRROR/$tarball"; else url="$GH_DL/v$v/$tarball"; fi

    echo
    rule
    printf "  %-16s %s\n" "version:"  "$v"
    printf "  %-16s %s\n" "source:"   "$url"
    printf "  %-16s %s\n" "sha256:"   "${LATEST_SHA:-(not published — cannot verify)}"
    printf "  %-16s %s\n" "unpacks to:" "$srcdir"
    rule
    echo
    echo "This installs PostgreSQL, FreeRADIUS, nginx and the SAMM daemons, creates a"
    echo "'samm' system user and a database, and enables systemd units. There is no"
    echo "uninstall script — removing it afterwards is a manual job."
    echo
    read -rp "Type INSTALL to proceed (anything else aborts): " answer || answer=""
    if [ "$answer" != "INSTALL" ]; then
        echo "Aborted — nothing was changed."
        return 1
    fi

    # No digest means we would run unverified code as root. That is a separate,
    # bigger decision than "install SAMM", so it gets its own typed word rather
    # than riding along on the previous confirmation.
    if [ -z "$LATEST_SHA" ]; then
        echo
        echo "WARNING: no sha256 was published for $tarball, so the download cannot be"
        echo "verified. The installer runs as root. Fetch the digest by hand from the"
        echo "release page if you would rather check it yourself."
        read -rp "Type UNVERIFIED to install anyway: " answer || answer=""
        if [ "$answer" != "UNVERIFIED" ]; then
            echo "Aborted — nothing was changed."
            return 1
        fi
    fi

    # A leftover tree from an interrupted attempt is moved aside rather than
    # deleted: it may hold the log of whatever went wrong last time.
    if [ -e "$srcdir" ]; then
        local bk=""
        bk="$srcdir.bak.$(date +%Y%m%d-%H%M%S)"
        echo "Moving previous $srcdir aside -> $bk"
        mv "$srcdir" "$bk"
    fi

    echo
    echo "Downloading $tarball ..."
    # Download to .part and rename only on success, so an interrupted transfer
    # can never be mistaken for a complete tarball on the next run. The stall
    # detector (--speed-time/--speed-limit) is used instead of a flat --max-time
    # because a genuinely slow rural link must still be able to finish.
    rm -f "$dest.part"
    if ! curl -fL --retry 3 --retry-delay 3 --connect-timeout 20 \
              --speed-time 120 --speed-limit 2048 -o "$dest.part" "$url"; then
        rm -f "$dest.part"
        echo "Download failed from $url"
        return 1
    fi
    mv "$dest.part" "$dest"

    if [ -n "$LATEST_SHA" ]; then
        local got=""
        got=$(sha256sum "$dest" | awk '{print $1}') || true
        if [ "$got" != "$LATEST_SHA" ]; then
            echo "sha256 MISMATCH — refusing to install."
            echo "  expected $LATEST_SHA"
            echo "  got      ${got:-none}"
            rm -f "$dest"
            return 1
        fi
        echo "sha256 verified."
    fi

    # A GitHub error page saved as .tar.gz is still a file; prove it is really
    # an archive before unpacking as root.
    if ! tar -tzf "$dest" >/dev/null 2>&1; then
        echo "$dest is not a valid gzip archive (a captive portal or error page?)."
        rm -f "$dest"
        return 1
    fi
    # And prove it only writes inside samm-<ver>/. tar strips a leading "/" but
    # happily follows ../ out of the extraction directory, which as root means
    # anywhere on the disk.
    if tar -tzf "$dest" 2>/dev/null | grep -qE '^/|(^|/)\.\.(/|$)'; then
        echo "$dest contains absolute or parent-relative paths — refusing to unpack it."
        rm -f "$dest"
        return 1
    fi
    # Every member must live under samm-<ver>/. Without this a tarball that
    # unpacks a differently named (or bare) tree would scatter files across
    # $WORKDIR as root, and the install.sh check below would only notice after
    # the damage was done.
    local tops=""
    tops=$(tar -tzf "$dest" 2>/dev/null | awk -F/ '$1 != "" {print $1}' | sort -u) || true
    if [ "$tops" != "samm-$v" ]; then
        echo "$dest does not unpack into a single samm-$v/ directory — refusing."
        printf '  it contains: %s\n' "$(printf '%s' "$tops" | tr '\n' ' ')"
        rm -f "$dest"
        return 1
    fi

    echo "Extracting to $srcdir ..."
    tar -xzf "$dest" -C "$WORKDIR"
    if [ ! -f "$srcdir/install.sh" ]; then
        echo "The archive did not contain $srcdir/install.sh — aborting."
        return 1
    fi

    echo
    echo "Running the SAMM installer (this takes several minutes)..."
    rule
    local rc=0
    {
        echo
        echo "=== samm-install wrapper: $(date '+%Y-%m-%d %H:%M:%S %Z') installing $v from $url ==="
    } >> "$INSTALL_LOG" 2>/dev/null || true
    # Run it in a subshell so its `cd` and any exported variables cannot leak
    # back here, and capture the status instead of letting set -e kill us — a
    # failed install is exactly when the report below matters most. pipefail is
    # switched on for the tee: without it the pipeline reports tee's status,
    # which is always 0, and a failed installer would look like a success.
    set -o pipefail
    ( cd "$srcdir" && bash ./install.sh ) 2>&1 | tee -a "$INSTALL_LOG" || rc=$?
    set +o pipefail
    rule

    if [ "$rc" -ne 0 ]; then
        echo
        echo "The installer exited with status $rc — the install is INCOMPLETE."
        echo "Do not re-run it blindly; read $INSTALL_LOG first."
        status_report || true
        return 1
    fi

    echo
    echo "Installer finished. Verifying services..."
    # systemd needs a beat after the final `systemctl start` before is-active
    # reports anything but "activating" for the slower units.
    sleep 5
    if status_report; then
        echo
        open_firewall
        echo
        echo "Done. Source tree kept at $srcdir (needed by the panel's updater)."
        return 0
    fi
    return 1
}

# --- menu ------------------------------------------------------------------

while true; do
    show
    if find_latest; then
        printf "  %-24s %s\n" "latest release:" "SAMM $LATEST_VER (via $LATEST_SRC)"
    else
        printf "  %-24s %s\n" "latest release:" "could not be checked (no internet?)"
    fi
    echo
    echo "  1) Run the pre-flight checks only (changes nothing)"
    echo "  2) Install the latest SAMM release"
    echo "  3) Show SAMM service status and the portal URL"
    echo "  4) Open the firewall for SAMM (ufw / firewalld)"
    echo "  5) Show the tail of the installer log"
    echo
    choice=""
    # read fails at end of input (someone piped this wizard something); treat
    # that exactly like pressing Enter, so it quits instead of looping forever.
    read -rp "Choice [Enter = quit]: " choice || choice=""

    case "${choice:-}" in
        1) preflight || true ;;
        2) do_install || true ;;
        3) status_report || true ;;
        4) open_firewall || true ;;
        5) if [ -r "$INSTALL_LOG" ]; then tail -n 60 "$INSTALL_LOG"; else echo "No $INSTALL_LOG on this box."; fi ;;
        "") echo "Nothing to do."; break ;;
        *) echo "'$choice' is not one of the choices." ;;
    esac
done
SCRIPT
chmod +x /usr/local/sbin/samm-install
echo "Installed. Run:  sudo samm-install"
EOF

sudo samm-install