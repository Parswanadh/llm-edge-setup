#!/bin/bash
# isolate.sh — Task 1 attribution: vary ONE factor at a time from a fixed baseline.
#
# BASELINE = the "fast" recipe that reproduced ~71 tok/s:
#   -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none
#   --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512
#   -ngl 16 -t 8 --context-shift --keep 4
#
# Every arm changes exactly ONE thing and is labelled with what it changed.
# Reports decode tok/s, prefill tok/s, VRAM, host-model-buffer split, and SWAP deltas.
#
# Uses llama-server.locked so we never race another worker's llama-server.
set -uo pipefail

OLLAMA_HOME=/home/parshu/.local/lib/ollama-new
export LD_LIBRARY_PATH="$OLLAMA_HOME:$OLLAMA_HOME/cuda_v13"
export GGML_BACKEND_PATH="$OLLAMA_HOME/cuda_v13/libggml-cuda.so"
LS="$OLLAMA_HOME/llama-server.locked"
M8=/home/parshu/.ollama/models/blobs/sha256-63c9be0cc3d5d7b0377161064a74c82b1a5a6ee9ba4a9a3cf034293d6dd09282
OUT=/tmp/opencode/iso
mkdir -p "$OUT"
PORT="${PORT:-19957}"
RESULTS="${RESULTS:-$OUT/results.jsonl}"

PROMPT="You are a helpful coding assistant. Analyze the following Python function and explain its time complexity, then suggest one optimization.

def find_pairs(nums, target):
    seen = {}
    for i, n in enumerate(nums):
        if target - n in seen:
            yield (seen[target - n], i)
        seen[n] = i

Explain step by step, then give the optimized version."
PJ=$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROMPT")

BASE=(-c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none
      --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512
      -ngl 16 -t 8 --context-shift --keep 4)

vmstat_get() { awk '/^pswpin /{print $2} /^pswpout /{print $3}' /proc/vmstat | tr '\n' ' '; }

arm() {  # $1=label $2=env string $3..=server args (FULL arg list)
  local label="$1"; shift
  local envs="$1"; shift
  local logf="$OUT/$label.server.log"

  local avail; avail=$(free -m | awk '/^Mem:/{print $7}')
  if [ "${avail:-0}" -lt 2000 ]; then
    echo "{\"label\":\"$label\",\"status\":\"low-ram\",\"avail_mb\":$avail}" | tee -a "$RESULTS"
    return 1
  fi

  # Port must be free AND must end up bound by OUR process. Another worker may
  # be squatting on the same port; a /health probe would then hit THEIR server
  # and every measurement would be garbage.
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "{\"label\":\"$label\",\"status\":\"port-busy\",\"port\":$PORT}" | tee -a "$RESULTS"
    return 1
  fi

  # shellcheck disable=SC2086
  env $envs timeout 420 "$LS" -m "$M8" --host 127.0.0.1 --port "$PORT" --no-webui --offline \
    --log-verbosity 4 --no-log-prefix --no-log-timestamps "$@" > "$logf" 2>&1 &
  local pid=$!
  local ok=0
  for _ in $(seq 1 150); do
    curl -s --max-time 2 "http://127.0.0.1:$PORT/health" | grep -q '"status":"ok"' && { ok=1; break; }
    kill -0 $pid 2>/dev/null || break
    sleep 2
  done
  if [ $ok -ne 1 ]; then
    echo "{\"label\":\"$label\",\"status\":\"load-fail\",\"err\":\"$(grep -aoE 'out of memory|failed to allocate[^,]{0,60}|error[^,]{0,80}' "$logf" | head -1 | tr -d '"')\"}" | tee -a "$RESULTS"
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 2; return 1
  fi

  # Verify the server answering on $PORT is OURS (not a squatter from another
  # worker). Compare the listening socket's inode owner against our process tree.
  local listener_pids
  listener_pids=$(ss -ltnp 2>/dev/null | grep ":$PORT " | grep -oE "pid=[0-9]+" | cut -d= -f2 | sort -u)
  local mine=0
  for lp in $listener_pids; do
    # walk up: the socket may be held by the `timeout` wrapper or the real binary
    local q=$lp
    for _ in 1 2 3 4; do
      [ "$q" = "$pid" ] && mine=1
      q=$(awk '{print $4}' /proc/$q/stat 2>/dev/null)
      [ -z "$q" ] && break
      [ "$q" = "1" ] && break
    done
  done
  if [ $mine -eq 0 ]; then
    echo "{\"label\":\"$label\",\"status\":\"port-hijacked\",\"port\":$PORT,\"listener_pids\":\"$listener_pids\"}" | tee -a "$RESULTS"
    kill -TERM $pid 2>/dev/null; sleep 2; kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 2; return 1
  fi

  local cubuf hostbuf kvbuf thr ctx ngl nb nlay
  cubuf=$(grep -aoE "CUDA0 model buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  hostbuf=$(grep -aoE "CUDA_Host model buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  kvbuf=$(grep -aoE "CUDA0 KV buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  thr=$(grep -aoE "n_threads = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  ctx=$(grep -aoE "n_ctx += *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  ngl=$(grep -aoE "n_gpu_layers = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  nb=$(grep -aoE "n_batch = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  nlay=$(grep -aoE "offloaded [0-9]+/[0-9]+ layers" "$logf" | tail -1 | grep -oE "[0-9]+/[0-9]+" | tr '/' 'x')

  local r=0
  while [ $r -lt 4 ]; do
    local swb swa sw_in sw_out resp rss vram
    swb=$(vmstat_get); swb="${swb:-0 0}"
    resp=$(curl -s --max-time 250 "http://127.0.0.1:$PORT/completion" -H 'Content-Type: application/json' \
      -d "{\"prompt\":$PJ,\"n_predict\":128,\"stream\":false,\"temperature\":0,\"seed\":42,\"cache_prompt\":false,\"timings_per_token\":true}")
    swa=$(vmstat_get); swa="${swa:-0 0}"
    sw_in=$(( ${swa%% *} - ${swb%% *} )); sw_out=$(( ${swa##* } - ${swb##* } ))
    rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$pid/status 2>/dev/null)
    vram=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    echo "$resp" | python3 -c "
import json,sys
try:
  d=json.load(sys.stdin); t=d.get('timings',{})
  print(json.dumps({'label':'$label','run':$r,'cold':$r==0,
    'decode_tps':round(t.get('predicted_per_second',0),2),
    'prefill_tps':round(t.get('prompt_per_second',0),2),
    'pred_n':t.get('predicted_n',0),
    'n_threads':${thr:-0},'n_ctx':${ctx:-0},'n_gpu_layers':${ngl:-0},'n_batch':${nb:-0},
    'layers_offloaded':'${nlay:-}',
    'cuda_model_mib':${cubuf:-0},'cpu_host_model_mib':${hostbuf:-0},'cuda_kv_mib':${kvbuf:-0},
    'vram_mb':$vram,'rss_mb':${rss:-0},
    'swap_in_pages':$sw_in,'swap_out_pages':$sw_out}))
except Exception as e:
  print(json.dumps({'label':'$label','run':$r,'error':str(e)[:120]}))
" | tee -a "$RESULTS"
    r=$((r+1)); sleep 1
  done
  kill -TERM $pid 2>/dev/null
  for _ in $(seq 1 20); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 3
}

case "${ARM:-all}" in
  V0)  arm V0_baseline "" "${BASE[@]}" ;;
  V1)  arm V1_env_ncmoe22 "LLAMA_ARG_N_CPU_MOE=22" "${BASE[@]}" ;;
  V2)  arm V2_cli_ncmoe22 "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 8 \
          --n-cpu-moe 22 --context-shift --keep 4 ;;
  V3)  arm V3_cli_ncmoe4 "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 8 \
          --n-cpu-moe 4 --context-shift --keep 4 ;;
  V4)  arm V4_ctx32768 "" -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 8 \
          --context-shift --keep 4 ;;
  V5)  arm V5_threads6 "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 6 \
          --context-shift --keep 4 ;;
  V6)  arm V6_batch512 "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 512 -ub 512 -ngl 16 -t 8 \
          --context-shift --keep 4 ;;
  V7)  arm V7_ngl99 "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 99 -t 8 \
          --context-shift --keep 4 ;;
  V8)  arm V8_env22_cli4 "LLAMA_ARG_N_CPU_MOE=22" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 8 \
          --n-cpu-moe 4 --context-shift --keep 4 ;;
  V9)  arm V9_mmap "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode mmap \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 8 \
          --context-shift --keep 4 ;;
  V10) arm V10_offloadminbatch1 "GGML_OP_OFFLOAD_MIN_BATCH=1" "${BASE[@]}" ;;
  V11) arm V11_faauto "" -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 1024 -ub 512 -ngl 16 -t 8 \
          --context-shift --keep 4 ;;
  V12) arm V12_np2 "" -c 4096 -np 2 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512 -ngl 16 -t 8 \
          --context-shift --keep 4 ;;
  V13) arm V13_ollama_full "" -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 \
          --context-shift --keep 4 ;;
  V14) arm V14_ollama_full_nocmoe "" -c 32768 -np 1 --no-jinja --chat-template chatml --load-mode none \
          --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn auto -b 512 -ub 512 -ngl 99 \
          --context-shift --keep 4 ;;
  *) echo "usage: ARM={V0..V14} $0"; exit 2;;
esac
