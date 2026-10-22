#!/usr/bin/env bash
# Reproduces the working llama-tq (TurboQuant) CUDA sm_89 build on this box.
#
# WHY THE EXTRA STEP
# The official CUDA archive's libggml-cpu.so is compiled with AVX-512 (its CI host
# had it): 10,026 zmm references. This machine's Intel Core Ultra 7 155H has NO
# AVX-512 (flags: avx avx2 avx_vnni fma f16c bmi2 gfni only), so the archive
# SIGILLs at startup inside ggml_cpu_init():
#     Illegal instruction (core dumped)
#     vmovdqa32 0xfe6a9(%rip),%zmm0
# The whole file is AVX-512, so it cannot be patched.
#
# FIX (no compile, no nvcc, no CUDA toolkit needed): take the *same release's*
# portable AVX2 CPU backend (libggml-cpu-haswell.so from the CPU-only archive of
# the same tag, same source commit b807e5c, same ggml 0.9.11 ABI) and swap it in.
# libggml.so only needs ggml_backend_cpu_reg from it, so the ABI matches.
# Everything else (llama-server, libllama, libggml, libggml-cuda) comes from the
# CUDA sm_89 archive, so the TurboQuant KV cache + CUDA backend stay intact.
#
# Usage:  bash setup-llama-tq.sh [install-dir]
#         default install-dir: $HOME/.local/lib/llama-tq
set -euo pipefail

ROOT="${1:-$HOME/.local/lib/llama-tq}"
TAG=v2026.10.19
mkdir -p "$ROOT"
cd "$ROOT"

# CUDA 12.8 runtime (libcudart.so.12 / libcublas.so.12).
# Present in BOTH ollama installs; prefer the rootless 0.40.8 tree, then system.
CUDART=""
for c in \
  "$HOME/.local/lib/ollama-new/cuda_v12" \
  "/usr/local/lib/ollama/cuda_v12" \
  "/usr/local/lib/ollama-new/cuda_v12"; do
  if [ -f "$c/libcudart.so.12" ]; then CUDART="$c"; break; fi
done
[ -n "$CUDART" ] || { echo "FATAL: no CUDA 12 runtime found (need libcudart.so.12)"; exit 1; }
echo "CUDA runtime: $CUDART"

SM89_URL="https://github.com/LL4nc33/llama-tq/releases/download/$TAG/llama-v2026.10.19-bin-ubuntu-cuda-12.8-sm89-x64.tar.gz"
CPU_URL="https://github.com/LL4nc33/llama-tq/releases/download/$TAG/llama-v2026.10.19-bin-ubuntu-x64.tar.gz"
SHA_SM89="58355b65647bf3c589ffaf9f6a9c02c0d378952aeb21a60e5807be8e4f4cbe8d"

[ -f llama-tq-sm89.tar.gz ] || curl -L --fail -o llama-tq-sm89.tar.gz "$SM89_URL"
[ -f llama-tq-cpu.tar.gz ]  || curl -L --fail -o llama-tq-cpu.tar.gz  "$CPU_URL"
echo "$SHA_SM89  llama-tq-sm89.tar.gz" | sha256sum -c -

rm -rf sm89 cpu merged
mkdir -p sm89 cpu merged
tar xzf llama-tq-sm89.tar.gz -C sm89
tar xzf llama-tq-cpu.tar.gz  -C cpu
cp -a sm89/llama-v2026.10.19/. merged/

# Swap the AVX-512 CPU backend for the AVX2 one from the same release.
rm -f merged/libggml-cpu.so merged/libggml-cpu.so.0 merged/libggml-cpu.so.0.9.11
cp cpu/llama-v2026.10.19/libggml-cpu-haswell.so merged/
ln -sf libggml-cpu-haswell.so merged/libggml-cpu.so
ln -sf libggml-cpu-haswell.so merged/libggml-cpu.so.0

export LD_LIBRARY_PATH="$ROOT/merged:$CUDART"
export GGML_BACKEND_PATH="$ROOT/merged"

"$ROOT/merged/llama-server" --version
"$ROOT/merged/llama-server" --list-devices
echo
echo "OK: $ROOT/merged/llama-server ready"
echo "Run with:"
echo "  export LD_LIBRARY_PATH=$ROOT/merged:$CUDART"
echo "  export GGML_BACKEND_PATH=$ROOT/merged"
