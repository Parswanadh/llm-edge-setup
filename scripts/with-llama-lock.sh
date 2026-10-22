#!/usr/bin/env bash
# Serialise llama-server runs on this box.
#
# This machine has 15 GiB RAM and has OOM-killed itself 31 times. A single
# LFM2.5-8B loaded with `--load-mode none` takes ~4.4 GB resident; two of them
# plus the desktop baseline exhausts RAM and the kernel starts swapping model
# weights, which makes every benchmark number meaningless.
#
# Usage:
#   bash with-llama-lock.sh <label> -- <llama-server args...>
#
# It:
#   1. takes an exclusive flock on /run/user/1000/llama-bench.lock
#   2. waits for any OTHER llama-server (including the one spawned by the
#      `ollama-rootless` systemd service, which a naive `pgrep llama-server`
#      check does distinguish but a naive `pgrep -f "port 1995"` check does not)
#   3. runs the command
#   4. cleans up and releases the lock
#
# It also refuses to start when available RAM is below MIN_AVAIL_MB.
set -uo pipefail

LABEL=${1:?usage: with-llama-lock.sh <label> -- <args...>}
shift
[ "${1:-}" = "--" ] && shift

MIN_AVAIL_MB=${MIN_AVAIL_MB:-2000}
LOCKFILE=${LOCKFILE:-/run/user/1000/llama-bench.lock}
TIMEOUT=${TIMEOUT:-1800}          # max wait for the lock, seconds
EXEC_TIMEOUT=${EXEC_TIMEOUT:-300}

exec 9>"$LOCKFILE"
if ! flock -w "$TIMEOUT" 9; then
  echo "[$LABEL] timed out after ${TIMEOUT}s waiting for the llama-server lock" >&2
  exit 75
fi

wait_for_clear() {
  local waited=0
  while :; do
    # count llama-server processes that are actually serving (not our own shell)
    local n
    n=$(pgrep -x llama-server 2>/dev/null | wc -l)
    if [ "$n" -eq 0 ]; then break; fi
    if [ "$waited" -ge 900 ]; then
      echo "[$LABEL] another llama-server is still running after ${waited}s; proceeding anyway" >&2
      break
    fi
    echo "[$LABEL] waiting for $n llama-server process(es) to exit (${waited}s)..." >&2
    sleep 15
    waited=$((waited + 15))
  done
}

avail=$(free -m | awk '/^Mem:/{print $7}')
if [ "$avail" -lt "$MIN_AVAIL_MB" ]; then
  echo "[$LABEL] only ${avail}MB available RAM (need ${MIN_AVAIL_MB}MB) — refusing" >&2
  exit 1
fi

wait_for_clear

echo "[$LABEL] starting (avail ${avail}MB)" >&2
trap 'pkill -f "llama-server.*${LABEL}" 2>/dev/null' EXIT
timeout "$EXEC_TIMEOUT" "$@"
rc=$?
echo "[$LABEL] finished rc=$rc" >&2
exit $rc
