#!/usr/bin/env bash
# Shared work queue for llama-server jobs on this box.
#
# WHY THIS EXISTS
# This laptop has 15 GiB RAM and has OOM-killed itself 31 times. One LFM2.5-8B
# loaded with `--load-mode none` costs ~4.4 GB resident; the 24B costs ~7.5 GB
# with `--n-cpu-moe 22`. Two at once exhausts RAM, the kernel swaps model
# weights, and every benchmark number becomes garbage.
#
# So: exactly ONE llama-server at a time, enforced by flock. Everything that
# does NOT need a model (docs, Modelfiles, API checks, service authoring) runs
# freely in parallel and is never gated by this queue.
#
# USAGE
#   bash llama-queue.sh run <label> -- <cmd...>     # run under the lock
#   bash llama-queue.sh status                       # who holds it, queue depth
#   bash llama-queue.sh done <label>                 # release (normally automatic)
#
# The lock is released automatically when the command exits, so a crashed job
# cannot wedge the queue.
set -uo pipefail

QUEUE_DIR="${QUEUE_DIR:-/run/user/1000/llm-queue}"
LOCK="$QUEUE_DIR/llama.lock"
CLAIM="$QUEUE_DIR/claim"
MIN_AVAIL_MB="${MIN_AVAIL_MB:-2000}"
WAIT_MAX="${WAIT_MAX:-2400}"

mkdir -p "$QUEUE_DIR"

case "${1:-}" in
  status)
    echo "queue dir : $QUEUE_DIR"
    if [ -f "$CLAIM" ]; then
      echo "held by   : $(cat "$CLAIM")  (since $(stat -c %y "$CLAIM" | cut -d. -f1))"
    else
      echo "held by   : (free)"
    fi
    echo "running   : $(pgrep -x llama-server 2>/dev/null | wc -l) llama-server process(es)"
    echo "avail RAM : $(free -m | awk '/^Mem:/{print $7}') MB"
    echo "swap      : $(free -m | awk '/^Swap:/{print $3}') MB used"
    exit 0
    ;;

  run)
    LABEL=${2:?usage: llama-queue.sh run <label> -- <cmd...>}
    shift 2
    [ "${1:-}" = "--" ] && shift
    [ $# -gt 0 ] || { echo "no command given" >&2; exit 1; }
    ;;

  *)
    echo "usage: $0 {run <label> -- <cmd...>|status}" >&2
    exit 1
    ;;
esac

# ---- take the exclusive lock ------------------------------------------------
exec 9>"$LOCK"
if ! flock -w "$WAIT_MAX" 9; then
  echo "[$LABEL] gave up waiting ${WAIT_MAX}s for the llama-server lock" >&2
  exit 75
fi

echo "$LABEL (pid $$, $(date +%H:%M:%S))" > "$CLAIM"
trap 'rm -f "$CLAIM"' EXIT

# ---- refuse to start if RAM is already too low -------------------------------
avail=$(free -m | awk '/^Mem:/{print $7}')
if [ "$avail" -lt "$MIN_AVAIL_MB" ]; then
  echo "[$LABEL] only ${avail}MB available (need ${MIN_AVAIL_MB}MB) — refusing to start" >&2
  exit 1
fi

# ---- also wait out any llama-server the lock holder does not own ------------
waited=0
while [ "$(pgrep -x llama-server 2>/dev/null | wc -l)" -gt 0 ]; do
  if [ "$waited" -ge 600 ]; then
    echo "[$LABEL] a llama-server is still alive after ${waited}s; proceeding (it may belong to the Ollama service)" >&2
    break
  fi
  echo "[$LABEL] waiting for existing llama-server(s) to exit (${waited}s)..." >&2
  sleep 15
  waited=$((waited + 15))
  avail=$(free -m | awk '/^Mem:/{print $7}')
  if [ "$avail" -lt "$MIN_AVAIL_MB" ]; then
    echo "[$LABEL] RAM dropped to ${avail}MB while waiting — refusing to start" >&2
    exit 1
  fi
done

echo "[$LABEL] starting (avail ${avail}MB)" >&2
"$@"
rc=$?
echo "[$LABEL] finished rc=$rc" >&2
exit $rc
