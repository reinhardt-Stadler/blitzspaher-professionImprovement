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

# Escalate only when the current user really cannot talk to the daemon.
# Being in the docker group is the normal case here; an unconditional sudo
# turns every docker call into a password prompt, and because verify redirects
# that output, a prompt that is never answered looks exactly like a hang.
SUDO=""
if [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1; then SUDO="sudo"; fi

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

# compose v2 validates project names: lowercase alnum, '-', '_' only, and a
# dot is rejected outright ("invalid project name"). Lab names such as
# fastjson-1.2.47 / shiro-1.2.4 carry dots, so normalize them away here instead
# of failing later inside `compose up` with output nobody sees.
project_name() {
  printf 'bz-lab-%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g'
}

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
# Ask docker for the compose project label instead of reverse-engineering the
# container name. Names are "<project>-<service>-<index>", so stripping only
# the trailing index left the service name behind and the comparison against
# project_name() never matched (status lied, and "stop the others first" was
# a no-op -> the next target collided on 8080, the failure this file exists to
# prevent).
running_projects() {
  $SUDO docker ps --filter 'label=com.docker.compose.project' \
    --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null \
    | grep '^bz-lab-' | sort -u
}

# Tear a project down by its label; works without the compose file in hand,
# which is what the "stop all" path needs (vulhub's root has no compose file).
stop_project() {
  local proj="$1"
  $SUDO docker ps -aq --filter "label=com.docker.compose.project=${proj}" 2>/dev/null \
    | xargs -r $SUDO docker rm -f >/dev/null 2>&1 || true
  $SUDO docker network ls -q --filter "label=com.docker.compose.project=${proj}" 2>/dev/null \
    | xargs -r $SUDO docker network rm >/dev/null 2>&1 || true
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
  # -e is required: the pattern starts with '-', which grep would otherwise
  # parse as an option and match nothing (silent: hit stays empty, port stays ?,
  # and every target is reported 'not ready' even though docker is fine).
  if [ -z "$hit" ]; then hit=$(printf '%s' "$ports" | tr ',' '\n' | grep -E -e '->' | head -1); fi
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
    for p in $others; do stop_project "$p"; done
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
    for p in $running; do stop_project "$p"; done
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

# ---------------------------------------------------------------------------
# verify: RA-5.1 one-shot acceptance
# ---------------------------------------------------------------------------
# Why this exists
#   RA-5.1 asks for "6-8 targets, at least 2 requiring a non-hardcoded CVE,
#   all resettable via compose up". Those are three claims that need evidence,
#   not a checklist. This subcommand produces that evidence in one run:
#   for each target -> start -> probe -> reset (down -v + up) -> probe again,
#   then stop. A target passes only if BOTH probes answer HTTP: the first proves
#   it comes up, the second proves reset returns it to a working initial state
#   (a target that comes up but cannot be reset twice is useless for repeat runs).
#
# Selection rule
#   Take up to $want present targets, but guarantee at least 2 with verifier=no
#   ("needs a non-hardcoded CVE") by taking those first. Without this the sample
#   could be all three built-in verifiers and the "2 non-hardcoded" claim would
#   be untested even though the run looked green.
cmd_verify() {
  need_dc
  local want="${1:-6}"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  local report="/tmp/labs-verify-${ts}.txt"

  say "RA-5.1 verify: target count = $want"
  say "vulhub: $VULHUB"
  [ -d "$VULHUB" ] || die "vulhub checkout not found. Set VULHUB=/path/to/vulhub"

  # Clear leftovers from an interrupted earlier run: a half-created container
  # still owns its host port, so `up` would fail on a port clash instead of on
  # the real problem.
  local stale; stale=$(running_projects)
  if [ -n "$stale" ]; then
    say "clearing leftover lab project(s): $(printf '%s' "$stale" | tr '\n' ' ')"
    for p in $stale; do stop_project "$p"; done
  fi

  # Build the candidate pool: only targets that exist on disk.
  local pool="" nonhc="" rest=""
  while IFS='|' read -r name path port cve ver; do
    [ -z "$name" ] && continue
    [ -f "$(compose_file "$path")" ] || continue
    pool="$pool$name|$path|$port|$cve|$ver\n"
    if [ "$ver" = "no" ]; then
      nonhc="$nonhc$name|$path|$port|$cve|$ver\n"
    else
      rest="$rest$name|$path|$port|$cve|$ver\n"
    fi
  done <<EOF
$(all_rows)
EOF

  local total; total=$(printf "$pool" | grep -c . || true)
  say "candidates present on disk: $total"
  if [ "$total" -eq 0 ]; then
    die "no candidate target exists in $VULHUB (see: lab.sh list)"
  fi

  # Selection: non-hardcoded first (need >=2), then fill from the rest.
  local selected="" picked=0 nonhc_picked=0
  while IFS='|' read -r name path port cve ver; do
    [ -z "$name" ] && continue
    [ "$picked" -ge "$want" ] && break
    if [ "$nonhc_picked" -lt 2 ]; then
      selected="$selected$name|$path|$port|$cve|$ver\n"; picked=$((picked+1)); nonhc_picked=$((nonhc_picked+1))
    fi
  done <<EOF
$(printf "$nonhc")
EOF
  # Fill the rest from the WHOLE pool, not just the verifier=yes bucket:
  # non-hardcoded targets beyond the first two were otherwise dropped, and the
  # sample came out one short whenever that bucket was the larger one.
  while IFS='|' read -r name path port cve ver; do
    [ -z "$name" ] && continue
    [ "$picked" -ge "$want" ] && break
    printf '%s' "$selected" | grep -qF "$name|" && continue
    selected="$selected$name|$path|$port|$cve|$ver\n"; picked=$((picked+1))
  done <<EOF
$(printf "$pool")
EOF

  say "selected $picked target(s) for verification, $nonhc_picked of them non-hardcoded"

  {
    say ""
    # Environment header: an acceptance record that cannot say where it ran is
    # not evidence. docker version decides whether compose v2 quirks applied.
    say "RA-5.1 acceptance run"
    say "  when   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    say "  host   : $(uname -srm)"
    say "  docker : $($SUDO docker info --format '{{.ServerVersion}} / {{.Driver}}' 2>/dev/null || echo unknown)"
    say "  vulhub : $VULHUB ($(ls "$VULHUB" 2>/dev/null | wc -l) entries)"
    say "  command: bash deploy/labs/lab.sh verify $want"
    say ""
    say "===== RA-5.1 VERIFY SUMMARY (paste this block back) ====="
    printf '%-20s %-6s %-6s %-6s %-8s %s\n' NAME PORT UP RESET VERDICT CVE
    say "----------------------------------------------------------------------------"
  } | tee "$report"

  local pass=0 fail=0 idx=0
  while IFS='|' read -r name path port cve ver; do
    [ -z "$name" ] && continue
    idx=$((idx+1))
    say ""
    say "--- [$idx/$picked] $name ($cve, verifier=$ver) ---"

    local up_ok="no" reset_ok="no" p1="" p2=""
    # Keep the output. Discarding it meant a failing target reported up=no with
    # no reason at all, and a slow `up` (image pull / docker build) looked like
    # a hang - both cost more than the lines they saved.
    local slog="$report.$idx.start.log" rlog="$report.$idx.reset.log"

    if cmd_start "$name" >"$slog" 2>&1; then
      p1=$(actual_port "$(project_name "$name")" "$port")
      http_ready "$p1" && up_ok="yes"
    fi
    say "  start  : up=$up_ok port=${p1:-?}"
    if [ "$up_ok" = "no" ]; then
      say "           log: $slog"
      tail -n 15 "$slog" 2>/dev/null | sed 's/^/           | /'
    fi

    if [ "$up_ok" = "yes" ]; then
      # reset = down -v + up. This is the part RA-5.1 actually cares about:
      # an exploited target must return to the image's initial state.
      if ( cd "$VULHUB" && $DC -p "$(project_name "$name")" -f "$(compose_file "$path")" down -v ) >"$rlog" 2>&1 \
         && cmd_start "$name" >>"$rlog" 2>&1; then
        p2=$(actual_port "$(project_name "$name")" "$port")
        http_ready "$p2" && reset_ok="yes"
      fi
      say "  reset  : ok=$reset_ok port=${p2:-?}"
      if [ "$reset_ok" = "no" ]; then
        say "           log: $rlog"
        tail -n 15 "$rlog" 2>/dev/null | sed 's/^/           | /'
      fi
    fi

    local verdict="FAIL"
    if [ "$up_ok" = "yes" ] && [ "$reset_ok" = "yes" ]; then verdict="PASS"; pass=$((pass+1)); else fail=$((fail+1)); fi

    printf '%-20s %-6s %-6s %-6s %-8s %s\n' "$name" "${p1:-?}" "$up_ok" "$reset_ok" "$verdict" "$cve" | tee -a "$report"

    # Always stop: next iteration must start from a clean port. Use the label
    # teardown so a broken compose context cannot mask the next target's state.
    stop_project "$(project_name "$name")"
  done <<EOF
$(printf "$selected")
EOF

  {
    say "----------------------------------------------------------------------------"
    say "total=$picked pass=$pass fail=$fail non_hardcoded=$nonhc_picked"
    if [ "$pass" -ge 6 ] && [ "$nonhc_picked" -ge 2 ]; then
      say "RA-5.1: PASS (>=6 resettable, >=2 non-hardcoded)"
    elif [ "$pass" -ge 6 ]; then
      say "RA-5.1: FAIL (>=6 resettable OK, but <2 non-hardcoded were actually verified)"
    else
      say "RA-5.1: FAIL ($pass < 6 resettable targets)"
    fi
  } | tee -a "$report"

  say ""
  say "report saved: $report"
  say "Paste the SUMMARY block above back; the acceptance table is filled from it."
}

case "${1:-}" in
  list)   cmd_list ;;
  start)  shift; cmd_start "${1:-}" ;;
  stop)   shift; cmd_stop "${1:-}" ;;
  reset)  shift; cmd_reset "${1:-}" ;;
  status) cmd_status ;;
  verify) shift; cmd_verify "${1:-6}" ;;
  *)
    say "usage: lab.sh <list|start <name>|stop [name]|reset <name>|status|verify [n]>"
    say ""
    say "  list          which labs exist in your vulhub checkout"
    say "  start <name>  start one target (stops others first: ports collide)"
    say "  stop [name]   stop one target, or all when no name given"
    say "  reset <name>  down -v then up, back to initial state"
    say "  status        what is running and whether it answers HTTP"
    say "  verify [n]    RA-5.1 acceptance: start/probe/reset/probe n targets (default 6)"
    exit 1
    ;;
esac
