#!/bin/bash
# Resumable, chunked-parallel downloader for the LFM2.5-24B QAD-Q4_0 GGUF.
# -C - resumes on retry; 8 parallel range workers; verifies sha256 at the end.
set -uo pipefail

URL="https://huggingface.co/LiquidAI/LFM2.5-24B-A2B-GGUF/resolve/main/LFM2.5-24B-A2B-QAD-Q4_0.gguf"
OUT="/home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
TOTAL=13578190880
WANT="89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
PARTS=8
WORK="/tmp/opencode/dl24"
LOG="/tmp/opencode/dl24.log"

mkdir -p "$WORK" /tmp/opencode
: > "$LOG"

CHUNK=$(( (TOTAL + PARTS - 1) / PARTS ))

worker() {
  local i=$1
  local start=$(( i * CHUNK ))
  local end=$(( start + CHUNK - 1 ))
  [ $end -ge $TOTAL ] && end=$(( TOTAL - 1 ))
  local f="$WORK/part.$i"
  local want_sz=$(( end - start + 1 ))
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
    local have=0
    [ -f "$f" ] && have=$(stat -c%s "$f")
    if [ "$have" -ge "$want_sz" ]; then
      echo "part $i complete ($have bytes)" >> "$LOG"
      return 0
    fi
    # Resume purely with an explicit Range header. Do NOT combine with
    # --continue-at (curl rejects that as a 400 on redirected HF CDN URLs).
    local tmp="$f.chunk"
    curl -sS -L --fail --retry 3 --retry-delay 2 \
         --connect-timeout 20 --max-time 1800 \
         --speed-limit 102400 --speed-time 60 \
         -H "Range: bytes=$(( start + have ))-$end" \
         -o "$tmp" "$URL" >> "$LOG" 2>> "$LOG"
    if [ $? -eq 0 ] && [ -s "$tmp" ]; then
      cat "$tmp" >> "$f"
    fi
    rm -f "$tmp"
    have=0; [ -f "$f" ] && have=$(stat -c%s "$f")
    if [ "$have" -ge "$want_sz" ]; then
      echo "part $i complete after attempt $attempt ($have bytes)" >> "$LOG"
      return 0
    fi
    echo "part $i attempt $attempt incomplete ($have/$want_sz), retrying" >> "$LOG"
    sleep 3
  done
  echo "part $i FAILED" >> "$LOG"
  return 1
}

echo "=== starting $PARTS parallel chunk workers, total $TOTAL bytes ===" >> "$LOG"
for i in $(seq 0 $(( PARTS - 1 ))); do
  worker "$i" &
done
wait
echo "=== all workers finished ===" >> "$LOG"

# Verify each part size
ok=1
for i in $(seq 0 $(( PARTS - 1 ))); do
  start=$(( i * CHUNK )); end=$(( start + CHUNK - 1 ))
  [ $end -ge $TOTAL ] && end=$(( TOTAL - 1 ))
  want_sz=$(( end - start + 1 ))
  got=0; [ -f "$WORK/part.$i" ] && got=$(stat -c%s "$WORK/part.$i")
  if [ "$got" -ne "$want_sz" ]; then
    echo "part $i size mismatch: got $got want $want_sz" >> "$LOG"; ok=0
  fi
done
[ "$ok" -eq 0 ] && { echo "=== SIZE CHECK FAILED ===" >> "$LOG"; exit 1; }

echo "=== concatenating parts ===" >> "$LOG"
cat "$WORK"/part.* > "${OUT}.tmp" 2>> "$LOG"
tsz=$(stat -c%s "${OUT}.tmp")
if [ "$tsz" -ne "$TOTAL" ]; then
  echo "concat size mismatch: $tsz != $TOTAL" >> "$LOG"; exit 1
fi

echo "=== verifying sha256 (this takes a few min for 13GB) ===" >> "$LOG"
got=$(sha256sum "${OUT}.tmp" | cut -d' ' -f1)
if [ "$got" = "$WANT" ]; then
  mv "${OUT}.tmp" "$OUT"
  echo "=== SHA256 OK, blob installed at $OUT ===" >> "$LOG"
  rm -rf "$WORK"
else
  echo "=== SHA256 MISMATCH: got $got want $WANT ===" >> "$LOG"
  exit 1
fi
