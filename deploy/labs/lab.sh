#!/usr/bin/env bash
# =============================================================================
# RA-5.1 lab controller: start / stop / reset ONE Vulhub target at a time.
#
# Why one at a time
#   Vulhub targets pin their own host port and most Java demos use 8080.
#   Running eight of them together collides immediately. Starting one at a
#   time also matches how the agent is actually used: one target per run,
#   evidence collected, then reset.
#
# Why it reads the port from docker instead of labs.txt
#   The compose files are the authority on port mapping. labs.txt only records
#   what we expect. If they disagree, the script reports the real one and
#   flags the drift, instead of probing a port nobody is listening on.
#
# Why "reset" is down -v then up
#   A exploited target keeps state (uploaded webshell, changed config). Reset
#   must return it to the image's initial state, otherwise run N+1 starts from
#   a different world than run N and the trace is not comparable.
#
# Usage (inside WSL):
#   bash deploy/labs/lab.sh list
#   bash deploy/labs/lab.sh start fastjson-1.2.47
#   bash deploy/labs/lab.sh status
#   bash deploy/labs/lab.sh reset fastjson-1.2.47
#   bash deploy/labs/lab.sh stop
#
# Env:
#   VULHUB=$HOME/vulhub        where the vulhub checkout lives
#   WAIT_SECONDS=60            readiness wait budget
#
# Pure ASCII on purpose (may be edited from a GBK Windows console).
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABS_FILE="$SCRIPT_DIR/labs.txt"
VULHUB="${VULHUB:-$HOME/vulhub}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

# docker compose v2 vs docker-compose v1.
# Resolved lazily: `list` must work on a machine without docker, because that
# is exactly when you want to see which targets a vulhub checkout provides.
DC=""
need_dc() {
  [ -n "$DC" ] && return 0
  if $SUDO docker compose version >/dev/null 2>&1; then
    DC="$SUDO docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="$SUDO docker-compose"
  else
    die "docker compose not available; install docker-compose-plugin"
  fi
}

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Lab table
# ---------------------------------------------------------------------------
# Prints "name|path|expect_port|cve|verifier" for the requested lab.
lab_row() {
  local want="$1"
  awk -F'|' -v want="$want" '
    /^[[:space:]]*#/ { next }
    NF < 5 { next }
    { for (i=1;i<=NF;i++) { gsub(/\r/, "", $i); gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
    $1 == want { print $1 "|" $2 "|" $3 "|" $4 "|" $5; found=1 }
    END { if (!found) exit 1 }
  ' "$LABS_FILE"
}

all_rows() {
  awk -F'|' '
    /^[[:space:]]*#/ { next }
    NF < 5 { next }
    { for (i=1;i<=NF;i++) { gsub(/\r/, "", $i); gsub(/^[ \t]+|[ \t]+$/, "", $i) } }
    { print $1 "|" $2 "|" $3 "|" $4 "|" $5 }
  ' "$LABS_FILE"
}

project_name() { printf 'bz-lab-%s' "$1"; }

compose_file() { printf '%s/%s/docker-compose.yml' "$VULHUB" "$1"; }

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
cmd_list() {
  say "vulhub : $VULHUB"
  [ -d "$VULHUB" ] || die "vulhub checkout not found. Set VULHUB=/path/to/vulhub"
  say ""
  printf '%-18s %-24s %-6s %-16s %-9s %s\n' NAME PATH PORT CVE VERIFIER PRESENT
  say "--------------------------------------------------------------------------------------------"
  local n=0 present=0
  while IFS='|' read -r name path port cve ver; do
    [ -z "$name" ] && continue
    n=$((n+1))
    local mark="no"
    if [ -f "$(compose_file "$path")" ]; then mark="yes"; present=$((present+1)); fi
    printf '%-18s %-24s %-6s %-16s %-9s %s\n' "$name" "$path" "$port" "$cve" "$ver" "$mark"
  done <<EOF
$(all_rows)
EOF
  say ""
  say "listed $n, present in this vulhub: $present"
  if [ "$present" -lt 6 ]; then
    say ""
    say "WARNING: fewer than 6 targets present. RA-5.1 asks for 6-8."
    say "  1) update the checkout:  cd $VULHUB && git pull --depth 1"
    say "  2) or pick different paths: ls $VULHUB | head -40"
  fi
}

# ---------------------------------------------------------------------------
# start / stop / reset / status
# ---------------------------------------------------------------------------
running_projects() {
  $SUDO docker ps --filter "name=bz-lab-" --format '{{.Names}}' 2>/dev/null | sed 's/-[0-9]*$//' | sort -u
}

# Read the actual host port for the running container, e.g. "0.0.0.0:8090->8090/tcp"
actual_port() {
  local proj="$1" expect="$2"
  local ports
  ports=$($SUDO docker ps --filter "name=${proj}" --format '{{.Ports}}' 2>/dev/null | head -1)
  [ -z "$ports" ] && { echo ""; return; }
  # Prefer the mapping whose container side equals the expected port, else take the first
  local hit
  hit=$(printf '%s' "$ports" | tr ',' '\n' | grep -E ":${expect}->" | head -1)
  if [ -z "$hit" ]; then hit=$(printf '%s' "$ports" | tr ',' '\n' | grep -E '->' | head -1); fi
  printf '%s' "$hit" | sed -E 's/.*:([0-9]+)->.*/\1/'
}

http_ready() {
  local port="$1"
  [ -z "$port" ] && return 1
  # Java demos answer 400/404 on "/", which is still "listening".
  local code
  code=$(curl -sS --noproxy '*' -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)
  [ -n "$code" ] && [ "$code" != "000" ]
}

cmd_start() {
  need_dc
  local name="${1:-}"
  [ -z "$name" ] && die "usage: lab.sh start <name>   (see: lab.sh list)"
  local row
  row=$(lab_row "$name") || die "unknown lab: $name (see: lab.sh list)"
  local path expect_port cve
  IFS='|' read -r _ path expect_port cve _ <<EOF
$row
EOF
  local cf; cf=$(compose_file "$path")
  [ -f "$cf" ] || die "compose file not found: $cf"

  # One at a time: stop any other bz-lab project first.
  local others
  others=$(running_projects | grep -v "^$(project_name "$name")" || true)
  if [ -n "$others" ]; then
    say "another lab is running: $others"
    say "stopping it first (Vulhub targets collide on port 8080)"
    for p in $others; do
      ( cd "$VULHUB" && $DC -p "$p" down >/dev/null 2>&1 ) || true
    done
  fi

  say "starting $name ($path, CVE $cve)"
  ( cd "$VULHUB" && $DC -p "$(project_name "$name")" -f "$cf" up -d ) || die "compose up failed"

  # Wait for readiness instead of sleeping a fixed time.
  local waited=0 port=""
  while [ "$waited" -lt "$WAIT_SECONDS" ]; do
    port=$(actual_port "$(project_name "$name")" "$expect_port")
    if [ -n "$port" ] && http_ready "$port"; then
      say "ready on port $port (waited ${waited}s)"
      [ "$port" != "$expect_port" ] && say "NOTE: actual port $port differs from labs.txt ($expect_port); using actual"
      say ""
      say "target for the agent: 127.0.0.1:$port"
      return 0
    fi
    sleep 2
    waited=$((waited+2))
  done

  say "NOT ready after ${WAIT_SECONDS}s"
  say "container state:"
  $SUDO docker ps -a --filter "name=$(project_name "$name")" --format '  {{.Names}}  {{.Status}}  {{.Ports}}'
  say "logs (tail):"
  $SUDO docker logs --tail 20 "$(project_name "$name")-1" 2>/dev/null || \
    $SUDO docker ps -aq --filter "name=$(project_name "$name")" | head -1 | xargs -r $SUDO docker logs --tail 20
  return 1
}

cmd_stop() {
  need_dc
  local name="${1:-}"
  if [ -z "$name" ]; then
    local running; running=$(running_projects)
    [ -z "$running" ] && { say "no lab running"; return 0; }
    say "stopping: $running"
    for p in $running; do ( cd "$VULHUB" && $DC -p "$p" down >/dev/null 2>&1 ) || true; done
    say "stopped"
    return 0
  fi
  local row; row=$(lab_row "$name") || die "unknown lab: $name"
  local path; IFS='|' read -r _ path _ _ _ <<EOF
$row
EOF
  ( cd "$VULHUB" && $DC -p "$(project_name "$name")" -f "$(compose_file "$path")" down ) || die "down failed"
  say "stopped $name"
}

cmd_reset() {
  need_dc
  local name="${1:-}"
  [ -z "$name" ] && die "usage: lab.sh reset <name>"
  local row; row=$(lab_row "$name") || die "unknown lab: $name"
  local path; IFS='|' read -r _ path _ _ _ <<EOF
$row
EOF
  local cf; cf=$(compose_file "$path")
  [ -f "$cf" ] || die "compose file not found: $cf"
  say "resetting $name (down -v, then up)"
  # -v removes volumes so the target returns to its initial state.
  ( cd "$VULHUB" && $DC -p "$(project_name "$name")" -f "$cf" down -v >/dev/null 2>&1 ) || true
  cmd_start "$name"
}

cmd_status() {
  need_dc
  local running; running=$(running_projects)
  if [ -z "$running" ]; then say "no bz-lab project running"; return 0; fi
  say "running labs:"
  while IFS='|' read -r name path port cve ver; do
    [ -z "$name" ] && continue
    local proj; proj=$(project_name "$name")
    if printf '%s\n' "$running" | grep -qx "$proj"; then
      local ap; ap=$(actual_port "$proj" "$port")
      local ok="not-ready"; http_ready "$ap" && ok="ready"
      say "  $name  port=${ap:-?}  $ok  ($cve)"
    fi
  done <<EOF
$(all_rows)
EOF
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  list)   cmd_list ;;
  start)  shift; cmd_start "${1:-}" ;;
  stop)   shift; cmd_stop "${1:-}" ;;
  reset)  shift; cmd_reset "${1:-}" ;;
  status) cmd_status ;;
  *)
    say "usage: lab.sh <list|start <name>|stop [name]|reset <name>|status>"
    say ""
    say "  list          which labs exist in your vulhub checkout"
    say "  start <name>  start one target (stops others first: ports collide)"
    say "  stop [name]   stop one target, or all when no name given"
    say "  reset <name>  down -v then up, back to initial state"
    say "  status        what is running and whether it answers HTTP"
    exit 1
    ;;
esac
