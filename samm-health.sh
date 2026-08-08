#!/usr/bin/env bash
sudo bash <<'EOF'
cat > /usr/local/sbin/samm-health <<'SCRIPT'
#!/bin/bash
set -e
[ "$EUID" -ne 0 ] && { echo "Run with sudo"; exit 1; }

# samm-health -- read-only diagnosis of a SAMM install on this box.
#
# Support asks a customer to run this and paste the output. It therefore MUST
# NOT change anything: every command below is a query. The single exception is
# the "save report" menu entry, which the operator has to pick deliberately and
# which only creates one text file under /root.
#
# It reports on BOTH shapes of install, because a box can legitimately carry
# both (a bare-OS install plus a compose stack), and a diagnosis that guessed
# one and ignored the other has sent people chasing services that were never
# supposed to be running.

WIDTH_LINE="----------------------------------------------------------------------"

# ---------------------------------------------------------------- findings ---
# Everything that matters is collected here rather than printed as a verdict on
# the spot, so the operator gets one actionable list at the end instead of
# having to re-read the whole report.
PROBLEMS=()
WARNS=()
prob() { PROBLEMS+=("$1"); }
warn() { WARNS+=("$1"); }

hdr()  { printf "\n%s\n%s\n" "$1" "$WIDTH_LINE"; }
row()  { printf "  %-30s %-6s %s\n" "$1" "$2" "$3"; }
note() { printf "      %s\n" "$1"; }

# ------------------------------------------------------------- http helper ---
# curl is not guaranteed on a minimal server image, so fall back to wget. Both
# are invoked with a short timeout: an unreachable port must not stall a
# support call for the default two minutes.
HTTP_TOOL=none
if command -v curl >/dev/null 2>&1; then HTTP_TOOL=curl
elif command -v wget >/dev/null 2>&1; then HTTP_TOOL=wget
fi

http_get() {
  # $1 = url. Prints the body on success, nothing on failure. Never fails, so
  # the caller can use it inside $( ) under set -e without an || true dance.
  case "$HTTP_TOOL" in
    curl) curl -fsS -k -m 4 "$1" 2>/dev/null || true ;;
    wget) wget -qO- --timeout=4 --tries=1 --no-check-certificate "$1" 2>/dev/null || true ;;
    *)    printf '' ;;
  esac
}

health_version() {
  # $1 = url of a /health endpoint. Prints the version SAMM reports, or nothing.
  # The check is deliberately strict about {"status":"ok"}: port 81 serves the
  # customer "subscription expired" portal, whose catch-all route answers /health
  # with a full HTML page. A naive "did I get a 200" test would call that healthy.
  local body ver
  body="$(http_get "$1")"
  case "$body" in
    *'"status":"ok"'*|*'"status": "ok"'*) : ;;
    *) return 0 ;;
  esac
  ver="$(printf '%s' "$body" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4)" || true
  printf '%s' "$ver"
}

# --------------------------------------------------------------- detection ---
INSTALL_BARE=no
INSTALL_DOCKER=no
DOCKER_NOTE=""
SAMM_CTRS=()
COMPOSE_PROJ=""
PG_CTR=""
API_CTR=""
FR_CTR=""
BARE_VER=""
DOCKER_VER=""

bare_version() {
  # Source checkouts carry app/version.py; a released install is Cython
  # compiled, version.py is gone and only version.<abi>.so is left -- so ask the
  # install's own interpreter rather than trying to read strings out of a binary.
  local v=""
  if [ -f /opt/samm/app/version.py ]; then
    v="$(grep -oE 'SAMM_VERSION[^"]*"[^"]+"' /opt/samm/app/version.py | tail -1 | cut -d'"' -f2)" || true
  fi
  if [ -z "$v" ] && [ -x /opt/samm/venv/bin/python ]; then
    v="$( cd /opt/samm && ./venv/bin/python -c 'from app.version import SAMM_VERSION; print(SAMM_VERSION)' 2>/dev/null )" || true
  fi
  # Printing nothing is a perfectly good answer here; callers must use
  # ${var:-unknown} because a function that prints nothing still SUCCEEDS and
  # so `$(bare_version) || echo unknown` would never fire.
  printf '%s' "$v"
}

detect_bare() {
  local unitfiles=""
  unitfiles="$(systemctl list-unit-files --no-legend --no-pager 'samm-*.service' 2>/dev/null)" || true
  if [ -f /etc/samm/samm.yaml ] || [ -x /opt/samm/venv/bin/python ] || [ -n "$unitfiles" ]; then
    INSTALL_BARE=yes
    BARE_VER="$(bare_version)" || true
  fi
}

in_set() {
  # $1 = a space-delimited set (with leading and trailing spaces), $2 = item.
  case "$1" in *" $2 "*) return 0 ;; esac
  return 1
}

detect_docker() {
  command -v docker >/dev/null 2>&1 || return 0
  if ! docker info >/dev/null 2>&1; then
    DOCKER_NOTE="docker is installed but the daemon is not answering"
    return 0
  fi

  local names=() c info img proj svc rest
  mapfile -t names < <(docker ps -a --format '{{.Names}}' 2>/dev/null) || true
  [ "${#names[@]}" -eq 0 ] && return 0

  declare -A IMGOF SVCOF PROJOF
  local projset=" " direct=" "
  for c in "${names[@]}"; do
    # `docker ps --format {{.Image}}` prints a bare image ID once the tag has
    # been removed (every rebuild of :latest untags the old one), which is why
    # the image is read from inspect and why the compose project and service
    # names are matched too -- on a box whose images are untagged they are the
    # only remaining evidence that this stack is SAMM.
    info="$(docker inspect -f '{{.Config.Image}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}' "$c" 2>/dev/null)" || info=""
    img="${info%%|*}"; rest="${info#*|}"; proj="${rest%%|*}"; svc="${rest##*|}"
    IMGOF["$c"]="$img"; PROJOF["$c"]="$proj"; SVCOF["$c"]="$svc"
    case "$img|$proj|$svc" in
      *samm*)
        if [ -n "$proj" ]; then
          if ! in_set "$projset" "$proj"; then projset="$projset$proj "; fi
        else
          direct="$direct$c "   # a hand-run `docker run`, no compose labels
        fi
        ;;
    esac
  done

  # Widen from the matched containers to their whole compose project: postgres
  # and freeradius run stock images, so an image-name match alone would drop
  # exactly the two sidecars that break most often.
  local add
  for c in "${names[@]}"; do
    add=no
    proj="${PROJOF[$c]}"
    if [ -n "$proj" ] && in_set "$projset" "$proj"; then add=yes; fi
    if in_set "$direct" "$c"; then add=yes; fi
    if [ "$add" = yes ]; then
      SAMM_CTRS+=("$c")
      img="${IMGOF[$c]}"; svc="${SVCOF[$c]}"
      case "$img $svc" in
        *postgres*)   PG_CTR="$c" ;;
        *freeradius*) FR_CTR="$c" ;;
      esac
      case "$svc" in
        samm-api|api|app) API_CTR="$c" ;;
      esac
    fi
  done
  [ "${#SAMM_CTRS[@]}" -eq 0 ] && return 0
  INSTALL_DOCKER=yes
  COMPOSE_PROJ="$(printf '%s' "$projset" | awk '{print $1}')" || true
}

# ------------------------------------------------------------- 1. install ----
sec_install() {
  hdr "1. INSTALL"
  detect_bare
  detect_docker

  if [ "$INSTALL_BARE" = yes ]; then
    row "bare-OS install" "[ OK ]" "/opt/samm  version ${BARE_VER:-unknown}"
    if [ -f /etc/samm/samm.yaml ]; then
      note "config: /etc/samm/samm.yaml"
    else
      row "  config file" "[FAIL]" "/etc/samm/samm.yaml is missing"
      prob "/etc/samm/samm.yaml is missing -- the services cannot read their DSN; restore it from backup."
    fi
    [ -z "$BARE_VER" ] && warn "Could not read the installed version from /opt/samm (neither app/version.py nor the venv import worked)."
  fi

  if [ "$INSTALL_DOCKER" = yes ]; then
    # The image carries no SAMM version label (org.opencontainers.image.version
    # is inherited from the Ubuntu base and says "24.04"), so the only honest
    # source is what the running app reports on /health, filled in later.
    row "docker install" "[ OK ]" "${#SAMM_CTRS[@]} containers${COMPOSE_PROJ:+, compose project '$COMPOSE_PROJ'}"
    [ -n "$API_CTR" ] && note "app container: $API_CTR (version read from /health below)"
  elif [ -n "$DOCKER_NOTE" ]; then
    row "docker" "[WARN]" "$DOCKER_NOTE"
    warn "$DOCKER_NOTE -- if this box is a Docker install, start docker first: systemctl start docker"
  fi

  if [ "$INSTALL_BARE" = no ] && [ "$INSTALL_DOCKER" = no ]; then
    row "SAMM" "[FAIL]" "no install found on this host"
    prob "No SAMM install found (no /opt/samm, no samm-* units, no SAMM containers). You are probably on the wrong machine."
  fi

  printf "\n"
  note "host   : $(hostname 2>/dev/null || echo '?')"
  note "os     : $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo '?')"
  note "kernel : $(uname -r 2>/dev/null || echo '?')"
  note "uptime : $(uptime -p 2>/dev/null || echo '?')"
  note "date   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
}

# ------------------------------------------------------------ 2. services ----
unit_state() {
  # Prints "<active> <enabled> <type>". Each of these commands PRINTS a useful
  # word AND exits non-zero when the answer is not "active"/"enabled"
  # (is-active exits 3 for inactive, 4 for a missing unit), so each capture is
  # guarded with || true and the VALUE is what we test afterwards -- never the
  # exit status, and never `x=$(cmd || echo none)` which would yield both words.
  local u="$1" a e t
  a="$(systemctl is-active "$u" 2>/dev/null)" || true
  e="$(systemctl is-enabled "$u" 2>/dev/null)" || true
  t="$(systemctl show -p Type --value "$u" 2>/dev/null)" || true
  printf '%s %s %s' "${a:-unknown}" "${e:-unknown}" "${t:-unknown}"
}

has_timer() {
  systemctl list-unit-files --no-legend --no-pager "${1%.service}.timer" 2>/dev/null | grep -q . && return 0
  return 1
}

check_unit() {
  local u="$1" st act ena typ
  st="$(unit_state "$u")"
  act="$(echo "$st" | awk '{print $1}')"
  ena="$(echo "$st" | awk '{print $2}')"
  typ="$(echo "$st" | awk '{print $3}')"

  case "$act" in
    active)
      row "$u" "[ OK ]" "active, $ena"
      ;;
    failed)
      row "$u" "[FAIL]" "FAILED, $ena"
      prob "$u has FAILED -- read the journal lines above, then: systemctl restart ${u%.service}"
      printf "\n"
      journalctl -u "$u" -n 10 --no-pager -o short-iso 2>/dev/null | sed 's/^/       /' || true
      printf "\n"
      ;;
    activating|deactivating|reloading)
      row "$u" "[WARN]" "$act (in transition)"
      warn "$u is stuck in state '$act' -- re-run samm-health in a minute; if it never settles, check its journal."
      ;;
    inactive)
      # A oneshot unit driven by a timer is SUPPOSED to be dead between runs.
      # Flagging those was the fastest way to make this report cry wolf.
      if [ "$typ" = "oneshot" ] || has_timer "$u"; then
        row "$u" "[ -- ]" "idle (runs on its timer)"
      elif [ "$ena" = "enabled" ]; then
        row "$u" "[FAIL]" "enabled but NOT running"
        prob "$u is enabled but not running -- start it: systemctl start ${u%.service}"
        printf "\n"
        journalctl -u "$u" -n 10 --no-pager -o short-iso 2>/dev/null | sed 's/^/       /' || true
        printf "\n"
      else
        row "$u" "[WARN]" "not running, $ena"
        warn "$u is not running and not enabled -- intentional? enable it: systemctl enable --now ${u%.service}"
      fi
      ;;
    *)
      row "$u" "[WARN]" "$act"
      ;;
  esac
}

sec_services() {
  hdr "2. SERVICES"
  if [ "$INSTALL_BARE" = no ] && [ "$INSTALL_DOCKER" = no ]; then
    row "samm services" "[ -- ]" "skipped, no SAMM install on this host"
    return 0
  fi

  if [ "$INSTALL_BARE" = yes ]; then
    local units=()
    mapfile -t units < <(systemctl list-unit-files --no-legend --no-pager 'samm-*.service' 2>/dev/null | awk '{print $1}' | sort -u) || true
    if [ "${#units[@]}" -eq 0 ]; then
      row "samm-* units" "[WARN]" "none installed"
      warn "No samm-*.service units are installed although /opt/samm exists -- an interrupted install?"
    else
      local u
      for u in "${units[@]}"; do check_unit "$u"; done
    fi

    # Timers matter on their own: if samm-updater.timer is dead the box silently
    # stops receiving updates while every service still looks perfectly healthy.
    local timers=()
    mapfile -t timers < <(systemctl list-unit-files --no-legend --no-pager 'samm-*.timer' 2>/dev/null | awk '{print $1}' | sort -u) || true
    local t st act
    for t in "${timers[@]}"; do
      st="$(unit_state "$t")"
      act="$(echo "$st" | awk '{print $1}')"
      if [ "$act" = "active" ]; then
        row "$t" "[ OK ]" "armed"
      else
        row "$t" "[WARN]" "$act"
        warn "$t is not armed -- its periodic job will never run: systemctl enable --now $t"
      fi
    done

    printf "\n"
    local dep
    for dep in nginx.service freeradius.service; do
      if systemctl list-unit-files --no-legend --no-pager "$dep" 2>/dev/null | grep -q .; then
        check_unit "$dep"
      fi
    done
    # The PostgreSQL unit name differs per release (postgresql.service wraps
    # postgresql@16-main.service), so take whatever is actually loaded here.
    local pgu=""
    pgu="$(systemctl list-units --no-legend --no-pager --all 'postgresql*.service' 2>/dev/null | sed 's/^[^a-zA-Z0-9]*//' | awk '{print $1}' | head -1)" || true
    [ -n "$pgu" ] && check_unit "$pgu"
  fi

  if [ "$INSTALL_DOCKER" = yes ]; then
    printf "\n"
    local c state health img
    for c in "${SAMM_CTRS[@]}"; do
      state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" || state="unknown"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c" 2>/dev/null)" || health=""
      case "$state" in
        running)
          if [ "$health" = "unhealthy" ]; then
            row "$c" "[FAIL]" "running but UNHEALTHY"
            prob "Container $c is running but its healthcheck fails -- docker logs --tail 50 $c"
            docker logs --tail 10 "$c" 2>&1 | sed 's/^/       /' || true
          else
            row "$c" "[ OK ]" "running${health:+, $health}"
          fi
          ;;
        restarting)
          row "$c" "[FAIL]" "restart loop"
          prob "Container $c is in a restart loop -- docker logs --tail 50 $c"
          docker logs --tail 10 "$c" 2>&1 | sed 's/^/       /' || true
          ;;
        exited|dead)
          row "$c" "[FAIL]" "$state"
          prob "Container $c is $state -- bring the stack back: docker compose up -d (from the bundle directory)"
          docker logs --tail 10 "$c" 2>&1 | sed 's/^/       /' || true
          ;;
        *)
          row "$c" "[WARN]" "$state"
          warn "Container $c is in state '$state'."
          ;;
      esac
    done
  fi
}

# ---------------------------------------------------------- 3. postgresql ----
DB_MODE=""      # local | peer | docker
DB_HOST=""; DB_PORT=""; DB_USER=""; DB_PASS=""; DB_NAME="samm"
DB_ANY_OK=no
# Every target that answered, remembered as parallel arrays: a box carrying both
# a bare-OS install and a compose stack has TWO separate databases, and reading
# the error board out of whichever happened to be probed last has already made
# a busy install look spotless because the idle one was empty.
OK_MODE=(); OK_HOST=(); OK_PORT=(); OK_USER=(); OK_PASS=(); OK_NAME=(); OK_CTR=(); OK_LABEL=()

psql_q() {
  # $1 = SQL, single-quoted literals only (no double quotes -- the peer-auth
  # path passes the statement through a nested shell where they would collide).
  # Always succeeds; the caller decides what an empty answer means.
  case "$DB_MODE" in
    local)
      PGPASSWORD="$DB_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
        -X -q -tA -v ON_ERROR_STOP=1 -c "$1" 2>/dev/null || true ;;
    peer)
      su - postgres -c "psql -X -q -tA -c \"$1\" $DB_NAME" 2>/dev/null || true ;;
    docker)
      docker exec -e PGPASSWORD="$DB_PASS" "$PG_CTR" \
        psql -U "$DB_USER" -d "$DB_NAME" -X -q -tA -c "$1" 2>/dev/null || true ;;
    *) printf '' ;;
  esac
}

parse_dsn() {
  # postgresql://user:pass@host:port/dbname
  # The password is generated and can itself contain '@', so split on the LAST
  # '@' (${x%@*} is the shortest-from-the-right cut) rather than the first.
  local raw creds hostpart hostport
  raw="${1#*://}"
  creds="${raw%@*}"
  hostpart="${raw##*@}"
  DB_USER="${creds%%:*}"
  DB_PASS="${creds#*:}"
  hostport="${hostpart%%/*}"
  DB_NAME="${hostpart#*/}"
  DB_NAME="${DB_NAME%%\?*}"
  DB_HOST="${hostport%%:*}"
  if [ "$hostport" = "$DB_HOST" ]; then DB_PORT=5432; else DB_PORT="${hostport##*:}"; fi
  [ -z "$DB_HOST" ] && DB_HOST=127.0.0.1
  [ -z "$DB_NAME" ] && DB_NAME=samm
}

db_report() {
  # $1 = human label for this target
  local label="$1" one schema ver size users routers sess conns maxconn where=""
  one="$(psql_q 'select 1')"
  if [ "$one" != "1" ]; then
    row "postgres ($label)" "[FAIL]" "not answering as $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME"
    prob "PostgreSQL is not answering for the SAMM database ($label). Every SAMM service is down until it does -- check the postgres service/container first, then the DSN in /etc/samm/samm.yaml."
    return 0
  fi
  DB_ANY_OK=yes
  OK_MODE+=("$DB_MODE"); OK_HOST+=("$DB_HOST"); OK_PORT+=("$DB_PORT"); OK_USER+=("$DB_USER")
  OK_PASS+=("$DB_PASS"); OK_NAME+=("$DB_NAME"); OK_CTR+=("$PG_CTR"); OK_LABEL+=("$label")

  ver="$(psql_q 'show server_version')"
  size="$(psql_q 'select pg_size_pretty(pg_database_size(current_database()))')"
  # server_version can be a whole sentence on Ubuntu ("16.14 (Ubuntu 16.14-...)"),
  # which pushes the line off a small terminal -- keep the number only.
  ver="${ver%% *}"
  # PG_CTR is set whenever a compose stack exists, so it must only be shown for
  # the container target -- naming it on the bare-OS line would be a lie.
  if [ "$DB_MODE" = docker ]; then where=" in $PG_CTR"; fi
  row "postgres ($label)" "[ OK ]" "server ${ver:-?}, db $DB_NAME ${size:+($size)}$where"

  schema="$(psql_q "select count(*) from information_schema.schemata where schema_name = 'samm'")"
  if [ "$schema" = "1" ]; then
    users="$(psql_q 'select count(*) from samm.user')"
    routers="$(psql_q 'select count(*) from samm.router')"
    sess="$(psql_q 'select count(*) from samm.session_active')"
    if [ -n "$users" ]; then
      row "  samm schema" "[ OK ]" "${users} subscribers, ${routers:-?} routers, ${sess:-?} live sessions"
    else
      row "  samm schema" "[FAIL]" "present but queries are refused"
      prob "The samm schema exists but $DB_USER cannot read samm.user -- a migration applied under the wrong role (it must be applied as the samm role, never as postgres)."
    fi
  else
    row "  samm schema" "[FAIL]" "missing from database $DB_NAME"
    prob "Database $DB_NAME has no 'samm' schema -- the install never finished, or the services point at the wrong database."
  fi

  conns="$(psql_q 'select count(*) from pg_stat_activity')"
  maxconn="$(psql_q "select setting from pg_settings where name = 'max_connections'")"
  if [ -n "$conns" ] && [ -n "$maxconn" ] && [ "$maxconn" -gt 0 ] 2>/dev/null; then
    local pct=$(( conns * 100 / maxconn ))
    if [ "$pct" -ge 90 ]; then
      row "  connections" "[FAIL]" "$conns / $maxconn (${pct}%)"
      prob "PostgreSQL is at ${pct}% of max_connections -- new SAMM requests will start failing with 'too many clients'. Restart the SAMM services to drop leaked pools, then look for a stuck worker."
    elif [ "$pct" -ge 70 ]; then
      row "  connections" "[WARN]" "$conns / $maxconn (${pct}%)"
      warn "PostgreSQL is at ${pct}% of max_connections."
    else
      row "  connections" "[ OK ]" "$conns / $maxconn"
    fi
  fi
}

sec_db() {
  hdr "3. POSTGRESQL"
  if [ "$INSTALL_BARE" = no ] && [ "$INSTALL_DOCKER" = no ]; then
    row "postgres" "[ -- ]" "skipped, no SAMM install on this host"
    return 0
  fi

  if [ "$INSTALL_BARE" = yes ]; then
    local cfg="" dsn=""
    # /etc/samm/samm.yaml is the live config. /opt/samm/etc/samm.yaml is the
    # shipped TEMPLATE and still holds the @DB_PASS@ placeholder, so it is only
    # a last resort and is treated as "no usable password" below.
    for cfg in /etc/samm/samm.yaml /opt/samm/etc/samm.yaml; do
      [ -f "$cfg" ] || continue
      dsn="$(grep -oE 'postgres(ql)?://[^"'"'"' ]+' "$cfg" | head -1)" || true
      [ -n "$dsn" ] && break
    done

    if [ -n "$dsn" ]; then
      parse_dsn "$dsn"
      case "$DB_PASS" in
        *@DB_PASS@*|"")
          DB_MODE=peer
          note "config holds no real password (template) -- falling back to peer auth as the postgres user"
          ;;
        *) DB_MODE=local ;;
      esac
    else
      DB_MODE=peer
      note "no DSN found in the config -- falling back to peer auth as the postgres user"
    fi

    if [ "$DB_MODE" = local ] && ! command -v psql >/dev/null 2>&1; then
      row "psql client" "[WARN]" "not installed"
      warn "psql is not installed, so the database could not be queried directly (apt install postgresql-client)."
      DB_MODE=""
    fi
    if [ "$DB_MODE" = peer ] && ! id postgres >/dev/null 2>&1; then
      row "postgres (bare-OS)" "[FAIL]" "no local postgres user and no usable DSN"
      prob "PostgreSQL does not appear to be installed on this host, but the bare-OS SAMM install expects it locally."
      DB_MODE=""
    fi

    if [ -n "$DB_MODE" ]; then
      db_report "bare-OS"
      # Peer auth proves the SERVER is up, not that SAMM's own credentials work
      # -- and a wrong password is exactly what a half-finished reinstall leaves
      # behind, so say so instead of implying a clean bill of health.
      [ "$DB_MODE" = peer ] && note "checked as the postgres superuser: SAMM's own DB credentials were NOT verified"
    fi
  fi

  if [ "$INSTALL_DOCKER" = yes ]; then
    if [ -z "$PG_CTR" ]; then
      row "postgres (docker)" "[WARN]" "no postgres container in the stack"
      warn "The compose stack has no postgres container -- an external database? Check docker-compose.yml."
    else
      local env_all=""
      env_all="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$PG_CTR" 2>/dev/null)" || true
      DB_USER="$(printf '%s\n' "$env_all" | sed -n 's/^POSTGRES_USER=//p' | head -1)" || true
      DB_PASS="$(printf '%s\n' "$env_all" | sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)" || true
      DB_NAME="$(printf '%s\n' "$env_all" | sed -n 's/^POSTGRES_DB=//p' | head -1)" || true
      [ -z "$DB_USER" ] && DB_USER=samm
      [ -z "$DB_NAME" ] && DB_NAME=samm
      DB_HOST="container"; DB_PORT="5432"
      DB_MODE=docker
      db_report "docker"
    fi
  fi
}

# ---------------------------------------------------------- 4. freeradius ----
sec_radius() {
  hdr "4. FREERADIUS"
  if [ "$INSTALL_BARE" = no ] && [ "$INSTALL_DOCKER" = no ]; then
    row "freeradius" "[ -- ]" "skipped, no SAMM install on this host"
    return 0
  fi

  local ports=()
  # Host-side UDP listeners. The local-address column is not at a fixed index
  # across ss versions (and `-p` adds a trailing one), so take the FIRST field
  # that looks like address:port and cut everything before the last colon --
  # which also makes an IPv6 socket ([::]:1812) parse like an IPv4 one.
  mapfile -t ports < <(ss -lnu 2>/dev/null | tail -n +2 \
      | awk '{for (i = 1; i <= NF; i++) if ($i ~ /:[0-9]+$/) { p = $i; sub(/.*:/, "", p); print p; break }}' \
      | sort -un) || true
  local plist=" ${ports[*]} "

  local auth=no acct=no
  case "$plist" in *" 1812 "*) auth=yes ;; esac
  case "$plist" in *" 1813 "*) acct=yes ;; esac

  if [ "$INSTALL_BARE" = yes ]; then
    local st act
    st="$(unit_state freeradius.service)"
    act="$(echo "$st" | awk '{print $1}')"
    if [ "$act" = "active" ]; then
      row "freeradius service" "[ OK ]" "active"
    else
      row "freeradius service" "[FAIL]" "$act"
      prob "freeradius is $act -- no router can authenticate a subscriber until it is running: systemctl restart freeradius"
    fi
  fi

  if [ "$auth" = yes ] && [ "$acct" = yes ]; then
    row "udp 1812 / 1813" "[ OK ]" "both listening on this host"
  elif [ "$INSTALL_DOCKER" = yes ] && [ -n "$FR_CTR" ]; then
    # Compose publishes RADIUS on the host, but if 1812 was already taken (a
    # bare-OS FreeRADIUS on the same box) it will be mapped to another port --
    # which routers pointed at the standard port cannot reach.
    local pub=""
    pub="$(docker port "$FR_CTR" 2>/dev/null | tr '\n' ' ')" || true
    if [ -n "$pub" ]; then
      row "udp 1812 / 1813" "[WARN]" "published as: $pub"
      warn "The RADIUS container is not on the standard ports (published: $pub). Routers must be pointed at the published port, or the port conflict resolved."
    else
      row "udp 1812 / 1813" "[FAIL]" "container publishes nothing"
      prob "The freeradius container publishes no host port, so routers cannot reach it -- the compose file's ports: section is missing or overridden."
    fi
  else
    row "udp 1812 / 1813" "[FAIL]" "auth=$auth acct=$acct"
    prob "FreeRADIUS is not listening on 1812/1813 udp -- authentication and accounting are both dead. Check: journalctl -u freeradius -n 50"
  fi

  # Naming the holder of the socket instantly settles "is this the bare-OS
  # daemon or a container's docker-proxy", which is the usual confusion on a
  # box that has carried both.
  local who=""
  who="$(ss -lnup 2>/dev/null | grep -E ':(1812|1813)[[:space:]]' | grep -oE 'users:\(\("[^"]+"' | grep -oE '"[^"]+"' | tr -d '"' | sort -u | tr '\n' ' ' | sed 's/ *$//')" || true
  [ -n "$who" ] && note "sockets held by: $who"

  if [ "$INSTALL_BARE" = yes ] && [ -d /etc/freeradius ]; then
    note "config: /etc/freeradius (not validated here -- 'freeradius -CX' is not read-only-safe on all boxes)"
  fi
}

# ------------------------------------------------------- 5. nginx / panel ----
sec_web() {
  hdr "5. NGINX / PANEL"
  if [ "$INSTALL_BARE" = no ] && [ "$INSTALL_DOCKER" = no ]; then
    row "panel" "[ -- ]" "skipped, no SAMM install on this host"
    return 0
  fi

  local running_ver=""

  if [ "$INSTALL_BARE" = yes ]; then
    local st act
    st="$(unit_state nginx.service)"
    act="$(echo "$st" | awk '{print $1}')"
    if [ "$act" = "active" ]; then
      row "nginx" "[ OK ]" "active"
    else
      row "nginx" "[FAIL]" "$act"
      prob "nginx is $act -- the admin panel and the customer portal are both unreachable: systemctl restart nginx"
    fi
  fi

  # Probe every port nginx actually listens on, plus the app's own port and any
  # port the API container publishes. -T reads the whole merged config, so
  # includes and extra vhosts are covered.
  local ports=()
  mapfile -t ports < <(nginx -T 2>/dev/null | awk '$1=="listen"{p=$2; sub(/;$/,"",p); sub(/.*:/,"",p); if (p ~ /^[0-9]+$/) print p}' | sort -un) || true
  ports+=(8000)
  local ctr_port=""
  if [ -n "$API_CTR" ]; then
    ctr_port="$(docker port "$API_CTR" 8000/tcp 2>/dev/null | head -1)" || true
    ctr_port="${ctr_port##*:}"
    [ -n "$ctr_port" ] && ports+=("$ctr_port")
  fi

  local seen=" " p v body answered=no
  for p in "${ports[@]}"; do
    if in_set "$seen" "$p"; then continue; fi
    seen="$seen$p "
    v="$(health_version "http://127.0.0.1:$p/health")"
    [ -z "$v" ] && v="$(health_version "https://127.0.0.1:$p/health")"
    if [ -n "$v" ]; then
      answered=yes
      if [ -n "$ctr_port" ] && [ "$p" = "$ctr_port" ]; then
        # This port belongs to the container stack, not to the bare-OS install,
        # so it must not be compared against the version on /opt/samm below.
        DOCKER_VER="$v"
        row "port $p" "[ OK ]" "/health ok, version $v (container $API_CTR)"
      else
        running_ver="$v"
        row "port $p" "[ OK ]" "/health ok, version $v"
      fi
    else
      body="$(http_get "http://127.0.0.1:$p/health")"
      if [ -n "$body" ]; then
        # Port 81 is the customer "subscription expired" vhost, whose catch-all
        # answers every path with an HTML page. It serving no JSON is correct,
        # not a fault, so it is reported as information rather than a warning.
        row "port $p" "[ -- ]" "answers, but not the API (portal vhost)"
      else
        row "port $p" "[WARN]" "nothing answers on this port"
      fi
    fi
  done

  if [ "$answered" = no ]; then
    if [ "$HTTP_TOOL" = none ]; then
      row "panel" "[WARN]" "neither curl nor wget is installed"
      warn "Could not probe the panel: install curl (apt install curl) and re-run."
    else
      row "panel" "[FAIL]" "nothing answered /health"
      prob "The panel answered /health on no port -- SAMM's API is down even if the unit looks alive. Check: journalctl -u samm-api -n 50"
    fi
  fi

  # A version mismatch between the files on disk and the process in memory is a
  # classic post-update state: the update landed but the service was never
  # restarted, so the panel keeps serving the old code.
  if [ -n "$running_ver" ] && [ -n "$BARE_VER" ] && [ "$running_ver" != "$BARE_VER" ]; then
    row "version match" "[WARN]" "on disk $BARE_VER, serving $running_ver"
    warn "The installed files are $BARE_VER but the running panel reports $running_ver -- restart the services so the new code is actually loaded: systemctl restart 'samm-*'"
  fi
  [ -n "$DOCKER_VER" ] && note "docker install reports version $DOCKER_VER"
}

# ----------------------------------------------------------- 6. resources ----
sec_resources() {
  hdr "6. DISK AND MEMORY"
  # Both of these take SAMM down in ways that look exactly like SAMM bugs: a
  # full disk stops PostgreSQL writing (every page 500s) and the OOM killer
  # picks off whichever python worker happens to be largest at the time.

  local paths=(/ /var /var/log /var/lib/postgresql /opt/samm)
  [ "$INSTALL_DOCKER" = yes ] && paths+=(/var/lib/docker)
  local seen=" " p line fs mnt use avail
  for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    line="$(df -P "$p" 2>/dev/null | tail -1)" || line=""
    [ -n "$line" ] || continue
    fs="$(echo "$line" | awk '{print $1}')"
    case "$seen" in *" $fs "*) continue ;; esac
    seen="$seen$fs "
    mnt="$(echo "$line" | awk '{print $6}')"
    use="$(echo "$line" | awk '{print $5}' | tr -d '%')"
    avail="$(df -Ph "$p" 2>/dev/null | tail -1 | awk '{print $4}')" || avail="?"
    if [ "$use" -ge 90 ] 2>/dev/null; then
      row "disk $mnt" "[FAIL]" "${use}% used, ${avail} free"
      prob "Filesystem $mnt is ${use}% full -- PostgreSQL and the logs will fail before SAMM does. Free space now (journalctl --vacuum-size=200M, old /opt/samm/dist tarballs, docker image prune)."
    elif [ "$use" -ge 80 ] 2>/dev/null; then
      row "disk $mnt" "[WARN]" "${use}% used, ${avail} free"
      warn "Filesystem $mnt is ${use}% full."
    else
      row "disk $mnt" "[ OK ]" "${use}% used, ${avail} free"
    fi

    # Inodes fill independently of bytes: a box with 60% space free can still
    # refuse to create a single file, and that failure reads as random 500s.
    local iuse
    iuse="$(df -Pi "$p" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')" || iuse=""
    if [ -n "$iuse" ] && [ "$iuse" -ge 90 ] 2>/dev/null; then
      row "  inodes $mnt" "[FAIL]" "${iuse}% used"
      prob "Filesystem $mnt has used ${iuse}% of its inodes -- nothing can create a new file. Delete small files in bulk (old sessions/logs)."
    fi
  done

  local mt ma sw sf
  mt="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)" || mt=""
  ma="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" || ma=""
  if [ -n "$mt" ] && [ -n "$ma" ] && [ "$mt" -gt 0 ]; then
    local mpct=$(( ma * 100 / mt ))
    local mtg mag
    mtg="$(awk -v k="$mt" 'BEGIN{printf "%.1f", k/1048576}')"
    mag="$(awk -v k="$ma" 'BEGIN{printf "%.1f", k/1048576}')"
    if [ "$mpct" -le 10 ]; then
      row "memory" "[FAIL]" "${mag}G available of ${mtg}G (${mpct}%)"
      prob "Only ${mpct}% of RAM is available -- the kernel will start killing SAMM workers. Add RAM or swap, or find the process that grew."
    elif [ "$mpct" -le 20 ]; then
      row "memory" "[WARN]" "${mag}G available of ${mtg}G (${mpct}%)"
      warn "Free memory is down to ${mpct}%."
    else
      row "memory" "[ OK ]" "${mag}G available of ${mtg}G (${mpct}%)"
    fi
  fi

  sw="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)" || sw=0
  sf="$(awk '/^SwapFree:/{print $2}' /proc/meminfo)" || sf=0
  if [ "${sw:-0}" -gt 0 ]; then
    local spct=$(( sf * 100 / sw ))
    if [ "$spct" -le 10 ]; then
      row "swap" "[WARN]" "${spct}% free"
      warn "Swap is ${spct}% free -- the box is already under memory pressure."
    else
      row "swap" "[ OK ]" "${spct}% free"
    fi
  else
    row "swap" "[ -- ]" "none configured"
  fi

  local oom
  oom="$(journalctl -k --since '7 days ago' --no-pager 2>/dev/null | grep -ciE 'out of memory: kill|oom-kill')" || true
  [ -z "$oom" ] && oom=0
  if [ "$oom" -gt 0 ] 2>/dev/null; then
    row "oom kills (7d)" "[FAIL]" "$oom in the kernel log"
    prob "The kernel OOM-killed a process $oom time(s) in the last 7 days -- services that 'randomly died' were killed by the box, not by a SAMM bug."
  else
    row "oom kills (7d)" "[ OK ]" "none"
  fi

  row "load average" "[ -- ]" "$(cut -d' ' -f1-3 /proc/loadavg) on $(nproc 2>/dev/null || echo '?') cpu"
}

# --------------------------------------------------------- 7. error board ----
sec_errors() {
  hdr "7. ERROR BOARD (last 7 days)"
  if [ "$DB_ANY_OK" != yes ]; then
    row "samm.error_report" "[ -- ]" "skipped, no database reachable"
    return 0
  fi

  local i exists rows incidents occurrences
  for i in "${!OK_MODE[@]}"; do
    # Re-point the query helper at each database that answered in section 3.
    DB_MODE="${OK_MODE[$i]}"; DB_HOST="${OK_HOST[$i]}"; DB_PORT="${OK_PORT[$i]}"
    DB_USER="${OK_USER[$i]}"; DB_PASS="${OK_PASS[$i]}"; DB_NAME="${OK_NAME[$i]}"
    PG_CTR="${OK_CTR[$i]}"

    exists="$(psql_q "select count(*) from information_schema.tables where table_schema = 'samm' and table_name = 'error_report'")"
    if [ "$exists" != "1" ]; then
      row "${OK_LABEL[$i]}" "[WARN]" "samm.error_report table is missing"
      warn "samm.error_report does not exist (${OK_LABEL[$i]}) -- this install predates the error board, or migration 0086 never ran."
      continue
    fi

    # Rows are deduped by fingerprint, so distinct rows = distinct bugs while
    # sum(count) = how often they actually happened. Quoting only one of the two
    # numbers has misled people in both directions, so print both.
    rows="$(psql_q "select count(*) || '|' || coalesce(sum(count), 0) from samm.error_report where last_seen > now() - interval '7 days'")"
    if [ -z "$rows" ]; then
      row "${OK_LABEL[$i]}" "[WARN]" "query refused"
      warn "Could not read samm.error_report (${OK_LABEL[$i]}) -- permissions?"
      continue
    fi
    incidents="${rows%%|*}"
    occurrences="${rows##*|}"

    if [ "${incidents:-0}" -eq 0 ] 2>/dev/null; then
      row "${OK_LABEL[$i]}" "[ OK ]" "no errors in the last 7 days"
    else
      row "${OK_LABEL[$i]}" "[WARN]" "$incidents distinct, $occurrences occurrences"
      warn "$incidents distinct error(s) in the last 7 days (${OK_LABEL[$i]}) -- open /admin/errors in the panel for the full traces."
      printf "\n"
      psql_q "select '       ' || incident_id || '  x' || count || '  ' || coalesce(exc_type, '?') || '  ' || coalesce(path, '-') from samm.error_report where last_seen > now() - interval '7 days' order by count desc limit 5"
      printf "\n"
    fi
  done
}

# -------------------------------------------------------------- 8. verdict ---
sec_summary() {
  hdr "SUMMARY"
  local i
  if [ "${#PROBLEMS[@]}" -eq 0 ] && [ "${#WARNS[@]}" -eq 0 ]; then
    printf "  PASS -- nothing to fix.\n"
    printf "\nRESULT: PASS\n"
    return 0
  fi
  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    printf "  PROBLEM -- %d thing(s) to fix:\n\n" "${#PROBLEMS[@]}"
    for i in "${!PROBLEMS[@]}"; do
      printf "   %d) %s\n\n" "$((i + 1))" "${PROBLEMS[$i]}"
    done
  else
    printf "  PASS with warnings -- nothing is broken right now.\n\n"
  fi
  if [ "${#WARNS[@]}" -gt 0 ]; then
    printf "  Worth a look (%d):\n\n" "${#WARNS[@]}"
    for i in "${!WARNS[@]}"; do
      printf "   - %s\n" "${WARNS[$i]}"
    done
    printf "\n"
  fi
  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    printf "RESULT: PROBLEM (%d)\n" "${#PROBLEMS[@]}"
  else
    printf "RESULT: PASS (%d warning(s))\n" "${#WARNS[@]}"
  fi
}

collect() {
  # Reset here as well as at declaration so a re-run from the menu never
  # inherits the previous run's findings.
  PROBLEMS=(); WARNS=()
  INSTALL_BARE=no; INSTALL_DOCKER=no; SAMM_CTRS=(); PG_CTR=""; API_CTR=""; FR_CTR=""
  COMPOSE_PROJ=""; DOCKER_NOTE=""; BARE_VER=""; DOCKER_VER=""
  DB_ANY_OK=no
  OK_MODE=(); OK_HOST=(); OK_PORT=(); OK_USER=(); OK_PASS=(); OK_NAME=(); OK_CTR=(); OK_LABEL=()
  printf "======================================================================\n"
  printf " SAMM HEALTH CHECK -- read-only, nothing on this box is changed\n"
  printf "======================================================================\n"
  sec_install
  sec_services
  sec_db
  sec_radius
  sec_web
  sec_resources
  sec_errors
  sec_summary
}

# ------------------------------------------------------------------- main ----
REPORT=""
run_report() {
  printf "Collecting (a few seconds)...\n" >&2
  # Captured whole so it can be saved verbatim on request. The summary is
  # printed by collect() itself precisely because command substitution runs in
  # a subshell -- the findings arrays would not survive out here.
  REPORT="$(collect 2>&1)" || true
  printf '%s\n' "$REPORT"
}

run_report

while :; do
  printf "\n%s\n" "$WIDTH_LINE"
  printf "  1) re-run the checks\n"
  printf "  2) show the last 50 journal lines of a unit\n"
  if [ "$INSTALL_DOCKER" = yes ] || command -v docker >/dev/null 2>&1; then
    printf "  3) show the last 50 log lines of a container\n"
  fi
  printf "  4) save this report to a file\n"
  printf "  Enter) quit\n"
  # `read` fails at end of input; without the guard set -e would kill the tool
  # with no message when the report is run from a non-interactive shell.
  read -rp "Choice: " CH || CH=""
  [ -z "$CH" ] && { printf "Nothing was changed on this box.\n"; break; }

  case "$CH" in
    1)
      run_report
      ;;
    2)
      UNITS=()
      mapfile -t UNITS < <(systemctl list-unit-files --no-legend --no-pager 'samm-*.service' 2>/dev/null | awk '{print $1}' | sort -u) || true
      UNITS+=(nginx.service freeradius.service)
      PGU="$(systemctl list-units --no-legend --no-pager --all 'postgresql*.service' 2>/dev/null | sed 's/^[^a-zA-Z0-9]*//' | awk '{print $1}' | head -1)" || true
      [ -n "$PGU" ] && UNITS+=("$PGU")
      printf "\n"
      for i in "${!UNITS[@]}"; do printf "  %2d) %s\n" "$((i + 1))" "${UNITS[$i]}"; done
      read -rp "Unit number (Enter to cancel): " UN || UN=""
      [ -z "$UN" ] && continue
      # Reject anything non-numeric before indexing: bash would evaluate "abc"
      # as 0, index -1, and quietly show the LAST unit instead of refusing.
      case "$UN" in *[!0-9]*) printf "Invalid choice.\n"; continue ;; esac
      SEL="${UNITS[$((UN - 1))]:-}"
      [ -z "$SEL" ] && { printf "Invalid choice.\n"; continue; }
      printf "\n"
      journalctl -u "$SEL" -n 50 --no-pager -o short-iso 2>&1 | sed 's/^/  /' || true
      ;;
    3)
      command -v docker >/dev/null 2>&1 || { printf "docker is not installed.\n"; continue; }
      CTRS=()
      mapfile -t CTRS < <(docker ps -a --format '{{.Names}}' 2>/dev/null) || true
      [ "${#CTRS[@]}" -eq 0 ] && { printf "No containers.\n"; continue; }
      printf "\n"
      for i in "${!CTRS[@]}"; do printf "  %2d) %s\n" "$((i + 1))" "${CTRS[$i]}"; done
      read -rp "Container number (Enter to cancel): " CN || CN=""
      [ -z "$CN" ] && continue
      case "$CN" in *[!0-9]*) printf "Invalid choice.\n"; continue ;; esac
      SEL="${CTRS[$((CN - 1))]:-}"
      [ -z "$SEL" ] && { printf "Invalid choice.\n"; continue; }
      printf "\n"
      docker logs --tail 50 "$SEL" 2>&1 | sed 's/^/  /' || true
      ;;
    4)
      # The only write this tool ever performs, and only when asked for it.
      OUT="/root/samm-health-$(date +%Y%m%d-%H%M%S).txt"
      printf '%s\n' "$REPORT" > "$OUT"
      chmod 600 "$OUT"
      printf "Saved: %s\n" "$OUT"
      printf "It contains hostnames and version numbers but no passwords.\n"
      ;;
    *)
      printf "Unknown choice.\n"
      ;;
  esac
done

exit 0
SCRIPT
chmod +x /usr/local/sbin/samm-health
echo "Installed. Run:  sudo samm-health"
EOF

sudo samm-health
