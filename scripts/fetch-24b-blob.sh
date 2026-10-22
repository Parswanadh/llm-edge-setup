#!/bin/bash
# fetch24b.sh — robust, resumable, parallel download of the LFM2.5-24B QAD-Q4_0 blob.
#
#   OUT = /home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa
#
# Design notes:
#  * Each of N chunks is written to its OWN file in WORK via `>>` (append), so a
#    dropped connection never loses bytes and never corrupts the offset.
#  * NO --retry on curl: curl's internal retry would replay the same Range and
#    append duplicate bytes. Retries are handled by the shell loop, which
#    recomputes the offset from the current file size.
#  * --http1.1: the CDN was emitting HTTP/2 stream CANCEL on long streams.
#  * Final assembly is byte-exact, then sha256-verified against the digest.
#  * Only after verification is the file moved to its final name.
set -uo pipefail

URL="https://registry.ollama.ai/v2/library/lfm2.5/blobs/sha256:89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
OUT="/home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
TOTAL=13578190880
WANT="89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
N=16
WORK=/tmp/opencode/dl24b
LOG=/tmp/opencode/dl24b.log
mkdir -p "$WORK" "$(dirname "$OUT")"
: > "$LOG"

CHUNK=$(( (TOTAL + N - 1) / N ))

worker() {
  local i=$1
  local start=$(( i * CHUNK ))
  local end=$(( start + CHUNK - 1 ))
  [ $end -ge $TOTAL ] && end=$(( TOTAL - 1 ))
  local f="$WORK/chunk.$i"
  local want=$(( end - start + 1 ))
  local attempt=0
  while [ $attempt -lt 400 ]; do
    attempt=$(( attempt + 1 ))
    local have=0
    [ -f "$f" ] && have=$(stat -c%s "$f")
    if [ "$have" -ge "$want" ]; then
      echo "chunk $i complete ($have bytes, attempt $attempt)" >> "$LOG"
      return 0
    fi
    curl -sS -L --fail --http1.1 --connect-timeout 30 --max-time 900 \
         --speed-limit 32768 --speed-time 120 \
         -H "Range: bytes=$(( start + have ))-$end" \
         "$URL" >> "$f" 2>> "$LOG"
    have=0
    [ -f "$f" ] && have=$(stat -c%s "$f")
    if [ "$have" -ge "$want" ]; then
      echo "chunk $i complete ($have bytes, attempt $attempt)" >> "$LOG"
      return 0
    fi
    # Truncate any overshoot (shouldn't happen) and continue.
    if [ "$have" -gt "$want" ]; then
      truncate -s "$want" "$f"
      echo "chunk $i truncated to $want" >> "$LOG"
      return 0
    fi
    echo "chunk $i attempt $attempt incomplete ($have/$want), retrying" >> "$LOG"
  done
  echo "chunk $i FAILED after $attempt attempts" >> "$LOG"
  return 1
}

for i in $(seq 0 $(( N - 1 ))); do worker "$i" & done
wait
echo "=== all workers done ===" >> "$LOG"

# ---- verify each chunk size ------------------------------------------------
ok=1
for i in $(seq 0 $(( N - 1 ))); do
  start=$(( i * CHUNK )); end=$(( start + CHUNK - 1 ))
  [ $end -ge $TOTAL ] && end=$(( TOTAL - 1 ))
  want=$(( end - start + 1 ))
  got=0
  [ -f "$WORK/chunk.$i" ] && got=$(stat -c%s "$WORK/chunk.$i")
  if [ "$got" -ne "$want" ]; then
    echo "chunk $i size mismatch: got $got want $want" >> "$LOG"; ok=0
  fi
done
[ "$ok" -eq 0 ] && { echo "=== SIZE CHECK FAILED ===" >> "$LOG"; exit 1; }

# ---- assemble ---------------------------------------------------------------
echo "=== concatenating ===" >> "$LOG"
cat $(for i in $(seq 0 $(( N - 1 ))); do echo "$WORK/chunk.$i"; done) > "${OUT}.tmp" 2>> "$LOG"
tsz=$(stat -c%s "${OUT}.tmp")
if [ "$tsz" -ne "$TOTAL" ]; then
  echo "concat size mismatch: $tsz != $TOTAL" >> "$LOG"; exit 1
fi

echo "=== verifying sha256 (a few min for 13GB) ===" >> "$LOG"
got=$(sha256sum "${OUT}.tmp" | cut -d' ' -f1)
if [ "$got" = "$WANT" ]; then
  mv "${OUT}.tmp" "$OUT"
  echo "=== SHA256 OK — blob installed at $OUT ===" >> "$LOG"
  rm -rf "$WORK"
else
  echo "=== SHA256 MISMATCH: got $got want $WANT ===" >> "$LOG"
  exit 1
fi
