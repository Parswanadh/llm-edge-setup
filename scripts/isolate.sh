#!/bin/bash
# isolate.sh — Task 1 attribution: vary ONE factor at a time from a fixed baseline.
#
# BASELINE = the "fast" recipe that reproduced 71 tok/s:
#   -c 4096 -np 1 --no-jinja --chat-template chatml --load-mode none
#   --cache-type-k q8_0 --cache-type-v q8_0 -fa on -b 1024 -ub 512
#   -ngl 16 -t 8 --context-shift --keep 4
#
# Each arm changes exactly one thing and is labelled with what it changed.
# Reports decode tok/s, prefill tok/s, VRAM, host-model-buffer split, and SWAP deltas.
set -uo pipefail

OLLAMA_HOME=/home/parshu/.local/lib/ollama-new
export LD_LIBRARY_PATH="$OLLAMA_HOME:$OLLAMA_HOME/cuda_v13"
export GGML_BACKEND_PATH="$OLLAMA_HOME/cuda_v13/libggml-cuda.so"
LS="$OLLAMA_HOME/llama-server"
M8=/home/parshu/.ollama/models/blobs/sha256-63c9be0cc3d5d7b0377161064a74c82b1a5a6ee9ba4a9a3cf034293d6dd09282
OUT=/tmp/opencode/iso
mkdir -p "$OUT"
PORT=19951

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

wait_gpu() {
  local w=0
  while :; do
    local others
    others=$(pgrep -af llama-server 2>/dev/null | grep -v pgrep | while read -r line; do
               local pid cmd
               pid=$(echo "$line" | awk '{print $1}')
               cmd=$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)
               case "$cmd" in *"llama-server --model "*) ;; *) echo "$line";; esac
             done)
    [ -z "$others" ] && return 0
    sleep 20; w=$((w+20)); [ $w -ge 2400 ] && return 1
  done
}

arm() {  # $1=label $2=env string $3..=server args (FULL arg list, not a delta)
  local label="$1"; shift
  local envs="$1"; shift
  wait_gpu || { echo "{\"label\":\"$label\",\"status\":\"gpu-timeout\"}"; return 1; }
  local avail; avail=$(free -m | awk '/Mem:/{print $7}')
  if [ "${avail:-0}" -lt 2000 ]; then echo "{\"label\":\"$label\",\"status\":\"low-ram\",\"avail_mb\":$avail}"; return 1; fi

  local logf="$OUT/$label.server.log"
  # shellcheck disable=SC2086
  env $envs timeout 300 "$LS" -m "$M8" --host 127.0.0.1 --port $PORT --no-webui --offline \
    --log-verbosity 4 --no-log-prefix --no-log-timestamps "$@" > "$logf" 2>&1 &
  local pid=$!
  local ok=0
  for _ in $(seq 1 120); do
    curl -s --max-time 2 "http://127.0.0.1:$PORT/health" | grep -q '"status":"ok"' && { ok=1; break; }
    kill -0 $pid 2>/dev/null || break
    sleep 2
  done
  if [ $ok -ne 1 ]; then
    echo "{\"label\":\"$label\",\"status\":\"load-fail\",\"err\":\"$(grep -aoE 'out of memory|failed to allocate[^,]{0,60}|error[^,]{0,80}' "$logf" | head -1 | tr -d '"')\"}"
    kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 2; return 1
  fi

  local cubuf hostbuf kvbuf thr ctx ngl nb
  cubuf=$(grep -aoE "CUDA0 model buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  hostbuf=$(grep -aoE "CPU_Host model buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  kvbuf=$(grep -aoE "CUDA0 KV buffer size = *[0-9.]+ MiB" "$logf" | tail -1 | grep -oE "[0-9.]+" | head -1)
  thr=$(grep -aoE "n_threads = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  ctx=$(grep -aoE "n_ctx += *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  ngl=$(grep -aoE "n_gpu_layers = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")
  nb=$(grep -aoE "n_batch = *[0-9]+" "$logf" | tail -1 | grep -oE "[0-9]+")

  local r=0
  while [ $r -lt 4 ]; do
    local swb swa sw_in sw_out resp rss vram
    swb=$(vmstat_get)
    resp=$(curl -s --max-time 250 "http://127.0.0.1:$PORT/completion" -H 'Content-Type: application/json' \
      -d "{\"prompt\":$PJ,\"n_predict\":128,\"stream\":false,\"temperature\":0,\"seed\":42,\"cache_prompt\":false,\"timings_per_token\":true}")
    swa=$(vmstat_get)
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
    'cuda_model_mib':${cubuf:-0},'cpu_host_model_mib':${hostbuf:-0},'cuda_kv_mib':${kvbuf:-0},
    'vram_mb':$vram,'rss_mb':${rss:-0},
    'swap_in_pages':$sw_in,'swap_out_pages':$sw_out}))
except Exception as e:
  print(json.dumps({'label':'$label','run':$r,'error':str(e)[:120]}))
"
    r=$((r+1)); sleep 1
  done
  kill -TERM $pid 2>/dev/null
  for _ in $(seq 1 20); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  kill -9 $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 2
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
  *) echo "usage: ARM={V0..V12|all} $0"; exit 2;;
esac
pgrep -af llama-server | grep -v pgrep || echo "clean"
