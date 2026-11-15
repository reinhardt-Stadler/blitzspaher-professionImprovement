#!/usr/bin/env bash
# =============================================================================
# RA-3.2 candidate measurement: is a container a usable isolated tool host?
#
# Why this script exists
#   The kernel can review generated tool code, but it cannot execute it: the
#   static rules are text checks, and the measured behaviour of
#   `node --permission` is "fs DENIED, child_process DENIED, net ALLOWED".
#   A generated tool could therefore connect to any host and bypass target
#   authorization. Container network isolation is the leading candidate fix.
#
# What this answers (docs/design/agent-refactor/45-RA3)
#   1. can the host be made unreachable?            -> --network=none
#   2. can it reach the lab only, not the internet? -> attach the lab network
#   3. is a read-only mount enforced?
#   4. can memory be capped?
#   5. how long does a one-shot container take?     (elimination line: > 2s)
#   6. can generated JS run inside, and what does it see when it tries out?
#
# Run inside WSL:
#   cd "/mnt/d/Reinhardt's_ITmessage/agentsbuild/blitzspaher-professionImprovement"
#   bash deploy/ra32-host-isolation.sh
#
# Overrides:
#   IMAGE=blitzspaher-agent:0.1
#   LAB_NET=<network name>            (default: auto-detect one matching "pentest")
#   TARGET=http://bz-target-fastjson:8090/
#   NET_TARGET=http://<reachable-without-proxy>/
#
# Two design notes, both learned the hard way
#
#   (a) ENTRYPOINT. The agent image declares ENTRYPOINT ["pi"], so
#       `docker run IMAGE sh -c 'command -v node'` becomes `pi sh -c ...`
#       and the command never runs -- which is exactly how the first run
#       reported "node: unknown". Every command here therefore goes through
#       run_sh(), which overrides the entrypoint with --entrypoint sh.
#
#   (b) PROXY. This host reaches the internet through a proxy; a container has
#       no proxy env, so "cannot reach the internet" would be TRUE even on the
#       default bridge. That is a false pass. NET_TARGET must therefore be
#       something the HOST can reach directly. If it cannot, the network rows
#       are marked SKIP instead of inventing a PASS.
#
# Pure ASCII on purpose (the file may be edited from a GBK Windows console).
# =============================================================================

set -u

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi

IMAGE="${IMAGE:-blitzspaher-agent:0.1}"
TARGET="${TARGET:-http://bz-target-fastjson:8090/}"

# NET_TARGET must be reachable by the HOST *without* a proxy (see note b above).
# Auto-pick the first candidate that the host can actually curl, so this script
# can be run with no arguments. Override with NET_TARGET=... if you have a
# better probe destination.
NET_TARGET_AUTO=0
if [ -z "${NET_TARGET:-}" ]; then
  for cand in \
    "http://www.baidu.com/" \
    "http://mirrors.aliyun.com/" \
    "http://$(ip route 2>/dev/null | awk '/default/{print $3; exit}'):80/"
  do
    case "$cand" in *"://:"*|*"://)") continue ;; esac
    if curl -sS --noproxy '*' -m 4 -o /dev/null "$cand" 2>/dev/null; then
      NET_TARGET="$cand"
      NET_TARGET_AUTO=1
      break
    fi
  done
fi
# Nothing reachable: keep a placeholder so the baseline row reports SKIP with a
# readable reason instead of crashing on an empty URL.
NET_TARGET="${NET_TARGET:-http://www.baidu.com/}"

pass=0; fail=0; skip=0

say()   { printf '%s\n' "$*"; }
head1() { say ""; say "------------------------------------------------------------------------"; say "$*"; say "------------------------------------------------------------------------"; }

record() { # record <PASS|FAIL|SKIP> <name> <evidence...>
  local state="$1"; shift
  local name="$1"; shift
  case "$state" in
    PASS) pass=$((pass+1)) ;;
    FAIL) fail=$((fail+1)) ;;
    SKIP) skip=$((skip+1)) ;;
  esac
  printf '[%s] %-44s %s\n' "$state" "$name" "$*"
}

# Run a shell command inside the image, bypassing its ENTRYPOINT.
# Usage: run_sh '<shell command>' [extra "docker run" args...]
run_sh() {
  local cmd="$1"; shift
  $SUDO docker run --rm --entrypoint sh "$@" "$IMAGE" -c "$cmd"
}

# ---------------------------------------------------------------------------
head1 "0. Preconditions"
# ---------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || { say "docker not in PATH. Run: sudo service docker start"; exit 1; }
$SUDO docker info >/dev/null 2>&1 || { say "daemon unreachable. Run: sudo service docker start"; exit 1; }
say "docker  : $(command -v docker)  server $($SUDO docker info --format '{{.ServerVersion}}' 2>/dev/null)"

if ! $SUDO docker image inspect "$IMAGE" >/dev/null 2>&1; then
  say "image not found: $IMAGE"
  say "available:"
  $SUDO docker images --format '  {{.Repository}}:{{.Tag}}' | head -20
  exit 1
fi
say "image   : $IMAGE"
say "entrypt : $($SUDO docker image inspect "$IMAGE" --format '{{json .Config.Entrypoint}}' 2>/dev/null) -> overridden with --entrypoint sh"

if [ -z "${LAB_NET:-}" ]; then
  LAB_NET="$($SUDO docker network ls --format '{{.Name}}' | grep -i 'pentest' | head -1)"
fi
say "lab net : ${LAB_NET:-<none found>}"

# Capability probe. Prints yes/no, and on failure shows why instead of hiding it.
probe_cap() { # probe_cap <binary>
  local out rc
  out=$(run_sh "command -v $1" --network=none 2>&1); rc=$?
  if [ $rc -eq 0 ] && [ -n "$out" ]; then
    echo "yes"
  else
    echo "no"
    say "  (probe of $1 failed: rc=$rc ${out:0:120})"
  fi
}

HAS_NODE=$(probe_cap node)
HAS_CURL=$(probe_cap curl)
say "node    : $HAS_NODE"
say "curl    : $HAS_CURL"

if [ "$HAS_CURL" != "yes" ]; then
  say ""
  say "This image exposes no curl through /bin/sh; network rows cannot run."
  say "Re-run with IMAGE=<image containing curl and node>, e.g. node:22-alpine"
  exit 1
fi

# ---------------------------------------------------------------------------
head1 "1. Host baseline: is NET_TARGET reachable directly, without proxy?"
# ---------------------------------------------------------------------------
say "  target: $NET_TARGET $([ "$NET_TARGET_AUTO" -eq 1 ] && echo '(auto-picked: host can curl it directly)')"
host_out=$(curl -sS --noproxy '*' -m 6 -o /dev/null -w 'http=%{http_code}' "$NET_TARGET" 2>&1); host_rc=$?
say "  raw   : $host_out  (curl exit=$host_rc)"

BASELINE_OK=0
if [ $host_rc -eq 0 ]; then
  record PASS "host reaches NET_TARGET directly" "$host_out"
  BASELINE_OK=1
else
  record SKIP "host reaches NET_TARGET directly" \
    "exit=$host_rc -- host has no direct egress, network rows cannot be measured"
  say "  This host only reaches the internet through a proxy, and a container"
  say "  has no proxy. Pick a target the HOST can curl without a proxy:"
  say "    NET_TARGET=\"http://\$(ip route | awk '/default/{print \$3}'):80/\" \\"
  say "      bash deploy/ra32-host-isolation.sh"
fi

# ---------------------------------------------------------------------------
head1 "2. Baseline container: default bridge SHOULD reach NET_TARGET"
# ---------------------------------------------------------------------------
if [ "$BASELINE_OK" -eq 0 ]; then
  record SKIP "default bridge reaches NET_TARGET" "host baseline unavailable"
else
  out=$(run_sh "curl -sS -m 6 -o /dev/null -w 'http=%{http_code}' $NET_TARGET" 2>&1); rc=$?
  say "  raw: $out  (exit=$rc)"
  if [ $rc -eq 0 ]; then
    record PASS "default bridge reaches NET_TARGET" "$out (control group valid)"
  else
    record FAIL "default bridge reaches NET_TARGET" "exit=$rc -- container has no egress at all"
  fi
fi

# ---------------------------------------------------------------------------
head1 "3. --network=none: MUST NOT reach NET_TARGET"
# ---------------------------------------------------------------------------
out=$(run_sh "curl -sS -m 6 -o /dev/null -w 'http=%{http_code}' $NET_TARGET" --network=none 2>&1); rc=$?
say "  raw: $out  (exit=$rc)"
if [ $rc -ne 0 ]; then
  record PASS "--network=none blocks outbound" "exit=$rc"
else
  record FAIL "--network=none blocks outbound" "reached $out despite no network"
fi

# ---------------------------------------------------------------------------
head1 "4. Lab network: outbound MUST fail, lab target MUST work"
# ---------------------------------------------------------------------------
if [ -z "${LAB_NET:-}" ]; then
  record SKIP "lab network outbound blocked" "no network matching 'pentest'"
  record SKIP "lab network target reachable" "no network matching 'pentest'"
else
  if [ "$BASELINE_OK" -eq 0 ]; then
    record SKIP "lab network outbound blocked" "host baseline unavailable"
  else
    out=$(run_sh "curl -sS -m 6 -o /dev/null -w 'http=%{http_code}' $NET_TARGET" --network="$LAB_NET" 2>&1); rc=$?
    say "  outbound raw: $out  (exit=$rc)"
    if [ $rc -ne 0 ]; then
      record PASS "lab network outbound blocked" "exit=$rc"
    else
      record FAIL "lab network outbound blocked" "internet reachable from $LAB_NET"
    fi
  fi

  out=$(run_sh "curl -sS -m 6 -o /dev/null -w 'http=%{http_code}' $TARGET" --network="$LAB_NET" 2>&1); rc=$?
  say "  target raw  : $out  ($TARGET, exit=$rc)"
  if [ $rc -eq 0 ]; then
    record PASS "lab network target reachable" "$TARGET -> $out"
  else
    record SKIP "lab network target reachable" "target down or not on $LAB_NET (run target.cmd first)"
  fi
fi

# ---------------------------------------------------------------------------
head1 "5. Read-only mount is enforced"
# ---------------------------------------------------------------------------
tmpd=$(mktemp -d); chmod 777 "$tmpd" 2>/dev/null || true
out=$(run_sh 'echo probe > /work/ra32.txt 2>&1 && echo WROTE || echo READONLY' -v "$tmpd:/work:ro" 2>&1)
say "  raw: $out"
case "$out" in
  READONLY*) record PASS "read-only mount enforced" "write rejected" ;;
  *)         record FAIL "read-only mount enforced" "container wrote into a :ro mount" ;;
esac
rm -rf "$tmpd" 2>/dev/null || true

# ---------------------------------------------------------------------------
head1 "6. Memory cap is enforced (128MB)"
# ---------------------------------------------------------------------------
out=$(run_sh 'cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo unknown' --memory=128m 2>&1)
say "  raw: $out"
case "$out" in
  *134217728*) record PASS "128MB memory cap applied" "cgroup=134217728" ;;
  *)           record FAIL "128MB memory cap applied" "cgroup=$out" ;;
esac

# ---------------------------------------------------------------------------
head1 "7. One-shot startup latency (3 runs, best of)"
# ---------------------------------------------------------------------------
best=999999
for i in 1 2 3; do
  start=$(date +%s%N)
  run_sh 'true' --network=none >/dev/null 2>&1
  end=$(date +%s%N)
  ms=$(( (end - start) / 1000000 ))
  say "  run $i: ${ms} ms"
  [ "$ms" -lt "$best" ] && best=$ms
done
if [ "$best" -le 2000 ]; then
  record PASS "startup within 2s" "best ${best} ms"
else
  record FAIL "startup within 2s" "best ${best} ms (elimination line: >2s needs budget review)"
fi

# ---------------------------------------------------------------------------
head1 "8. Generated JS executes inside"
# ---------------------------------------------------------------------------
if [ "$HAS_NODE" != "yes" ]; then
  record SKIP "node executes in container" "image has no node"
else
  out=$(run_sh 'node -e "console.log(1+1)"' --network=none 2>&1)
  say "  raw: $out"
  case "$out" in
    *2*) record PASS "node executes in container" "node -e printed $out" ;;
    *)   record FAIL "node executes in container" "$out" ;;
  esac
fi

# ---------------------------------------------------------------------------
head1 "9. Physical evidence: what a generated tool sees on an outbound call"
# ---------------------------------------------------------------------------
say "  (this row is the proof -- not the code review, the socket error itself)"
if [ "$HAS_NODE" != "yes" ]; then
  record SKIP "outbound socket refused at OS level" "image has no node"
else
  JS="const net=require('net');const s=net.connect(80,'1.1.1.1');s.setTimeout(4000);"
  JS="${JS}s.on('connect',()=>{console.log('REACHED');s.destroy();});"
  JS="${JS}s.on('error',(e)=>{console.log('BLOCKED:'+e.code);});"
  JS="${JS}s.on('timeout',()=>{console.log('TIMEOUT');s.destroy();});"
  out=$(run_sh "node -e \"$JS\"" --network=none 2>&1)
  say "  raw: $out"
  last=$(printf '%s' "$out" | tail -1)
  case "$last" in
    BLOCKED:*|TIMEOUT*) record PASS "outbound socket refused at OS level" "$last" ;;
    REACHED*)          record FAIL "outbound socket refused at OS level" "socket opened under --network=none" ;;
    *)                 record FAIL "outbound socket refused at OS level" "unexpected: $last" ;;
  esac
fi

# ---------------------------------------------------------------------------
head1 "SUMMARY  PASS=$pass  FAIL=$fail  SKIP=$skip"
# ---------------------------------------------------------------------------
say ""
say "Reading the result"
say "  host baseline PASS + none PASS + lab-out PASS + lab-target PASS"
say "      -> container can host generated tools; lab-only network is the mode to use"
say "  host baseline SKIP"
say "      -> this host has no direct egress; re-run with NET_TARGET pointing at"
say "         something reachable without proxy, otherwise rows 2-4 prove nothing"
say "  startup FAIL (>2s)"
say "      -> still usable, but each tool call costs that much; needs budget review"
say ""
say "Paste the whole output back; the RA-3.2 decision is made from these numbers."
