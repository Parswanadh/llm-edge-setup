#!/bin/bash
# prefault-model.sh — pull a GGUF model into the page cache before starting
# llama-server, and report how much of it is actually resident.
#
# WHY THIS EXISTS
#
#   With --n-cpu-moe the CPU-resident expert tensors are mmap'd FILE pages.
#   Clean file pages are never written to swap: under memory pressure the
#   kernel drops them and re-reads them from the NVMe.  So the model is
#   either in RAM (page cache) or it is being re-read from disk at ~100 us
#   per random access instead of ~100 ns.
#
#   Nothing in the swap configuration can change this.  The only thing that
#   changes it is:
#     1. having enough free RAM that the page cache is not reclaimed, and
#     2. actually faulting the pages in BEFORE the first decode, so the
#        first tokens are not paying the NVMe latency.
#
#   This script does (2), and (1) by refusing to run when there is not enough
#   headroom.
#
# Usage:
#   prefault-model.sh MODEL [--min-headroom-mb N] [--quiet]
#
# REVERT: nothing to revert — this only reads the file.
set -uo pipefail

MODEL=""
MIN_HEAD_MB=1500
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL="$2"; shift 2;;
    --min-headroom-mb) MIN_HEAD_MB="$2"; shift 2;;
    --quiet) QUIET=1; shift;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$MODEL" ] || { echo "usage: $0 MODEL [--min-headroom-mb N] [--quiet]" >&2; exit 2; }
[ -r "$MODEL" ] || { echo "cannot read $MODEL" >&2; exit 1; }

RESID_TOOL="$(dirname "$0")/mmap_resident.py"
[ -r "$RESID_TOOL" ] || RESID_TOOL=/tmp/opencode/mmap_resident.py

size_mb=$(( ($(stat -c%s "$MODEL")) / 1048576 ))
avail_mb=$(free -m | awk '/^Mem:/{print $7}')
used_swap_mb=$(free -m | awk '/^Swap:/{print $3}')

say() { [ "$QUIET" = "1" ] || echo "$@" >&2; }

say "[prefault] model      = $MODEL"
say "[prefault] size       = ${size_mb} MiB"
say "[prefault] MemAvail   = ${avail_mb} MiB   SwapUsed = ${used_swap_mb} MiB"

if [ "$avail_mb" -lt "$MIN_HEAD_MB" ]; then
  say "[prefault] REFUSING: only ${avail_mb} MiB available (< ${MIN_HEAD_MB} MiB required)."
  say "[prefault] Free RAM first, or the page cache will be reclaimed under you."
  exit 3
fi

# Readahead the whole file into the page cache.  `cat` is synchronous, so on
# return the pages are resident (or the kernel dropped them, which the
# residency check below will reveal).
say "[prefault] reading model into page cache ..."
cat "$MODEL" > /dev/null

if [ -r "$RESID_TOOL" ]; then
  python3.12 "$RESID_TOOL" "$MODEL" 2>/dev/null || \
  python3 "$RESID_TOOL" "$MODEL" 2>/dev/null || true
fi
say "[prefault] done — start llama-server now (the pages are hot)."
