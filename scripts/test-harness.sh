#!/usr/bin/env bash
#
# test-harness.sh — exercise the non-privileged parts of upgrade-ollama.sh
# inside a throwaway sandbox. It extracts the REAL functions from the real
# script (no copy-paste drift) and runs them against fake paths.
#
#   bash /tmp/opencode/upgrade/test-harness.sh
#
set -euo pipefail

SCRIPT="/tmp/opencode/upgrade-ollama.sh"
SB="/tmp/opencode/upgrade/sandbox"
rm -rf "$SB"; mkdir -p "$SB"

PASS=0; FAIL=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1;36m-- %s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
# Extract real functions from the real script
# --------------------------------------------------------------------------
extract_fn() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" {inblock=1}
    inblock {print}
    inblock && $0 == "}" {exit}
  ' "$SCRIPT"
}

head_ "Extracting functions from $SCRIPT"
FUNCFILE="$SB/funcs.sh"
: > "$FUNCFILE"
for fn in snapshot_models write_unit_file count_matches client_version server_version; do
  body="$(extract_fn "$fn")"
  if [ -z "$body" ]; then bad "could not extract $fn"; else ok "extracted $fn"; fi
  printf '%s\n' "$body" >> "$FUNCFILE"
done
# shellcheck disable=SC1090
source "$FUNCFILE"

OLLAMA_USER=ollama
OLLAMA_GROUP=ollama

# --------------------------------------------------------------------------
head_ "1) snapshot_models on a fake store"
FAKE="$SB/store"
mkdir -p "$FAKE/manifests/registry.ollama.ai/library" "$FAKE/blobs"
printf 'm1\n' > "$FAKE/manifests/registry.ollama.ai/library/a"
printf 'm2\n' > "$FAKE/manifests/registry.ollama.ai/library/b"
printf 'blob1\n' > "$FAKE/blobs/sha256-aaa"
printf 'blob2\n' > "$FAKE/blobs/sha256-bbb"
MODEL_STORE="$FAKE"
snapshot_models "$SB/before.txt"
B_MANIFESTS="$(count_matches 'registry' < "$SB/before.txt")"
B_BLOBS="$(count_matches 'sha256-' < "$SB/before.txt")"
[ "$B_MANIFESTS" -eq 2 ] && ok "manifest count = $B_MANIFESTS" || bad "manifest count = $B_MANIFESTS (want 2)"
[ "$B_BLOBS" -eq 2 ] && ok "blob count = $B_BLOBS" || bad "blob count = $B_BLOBS (want 2)"

head_ "2) snapshot is stable when nothing changes"
snapshot_models "$SB/after.txt"
if diff -q "$SB/before.txt" "$SB/after.txt" >/dev/null; then ok "no diff on unchanged store"; else bad "diff on unchanged store"; fi

head_ "3) snapshot detects a changed blob"
printf 'blob1-CHANGED\n' > "$FAKE/blobs/sha256-aaa"
snapshot_models "$SB/after2.txt"
if diff -q "$SB/before.txt" "$SB/after2.txt" >/dev/null; then bad "changed blob NOT detected"; else ok "changed blob detected"; fi
printf 'blob1\n' > "$FAKE/blobs/sha256-aaa"

head_ "4) snapshot detects a deleted manifest"
mv "$FAKE/manifests/registry.ollama.ai/library/b" "$SB/b.moved"
snapshot_models "$SB/after3.txt"
if diff -q "$SB/before.txt" "$SB/after3.txt" >/dev/null; then bad "deleted manifest NOT detected"; else ok "deleted manifest detected"; fi
mv "$SB/b.moved" "$FAKE/manifests/registry.ollama.ai/library/b"

# --------------------------------------------------------------------------
head_ "5) write_unit_file output"
OLD_UNIT="$SB/ollama.service.old"
cat > "$OLD_UNIT" <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/home/parshu/.local/bin:/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=default.target
EOF
PATH_LINE="$(grep -m1 '^Environment="PATH=' "$OLD_UNIT")"
write_unit_file "$SB/ollama.service" "/usr/local/bin/ollama" "/usr/share/ollama/.ollama/models" "$PATH_LINE"
cat "$SB/ollama.service" | sed 's/^/      /'
grep -q 'Environment="OLLAMA_MODELS=/usr/share/ollama/.ollama/models"' "$SB/ollama.service" \
  && ok "OLLAMA_MODELS pinned to the 31 GB store" || bad "OLLAMA_MODELS missing"
grep -q 'Environment="OLLAMA_HOST=127.0.0.1:11434"' "$SB/ollama.service" \
  && ok "OLLAMA_HOST pinned to 11434" || bad "OLLAMA_HOST missing"
grep -q "ExecStart=/usr/local/bin/ollama serve" "$SB/ollama.service" \
  && ok "ExecStart unchanged" || bad "ExecStart wrong"
grep -q "^User=ollama" "$SB/ollama.service" && ok "User=ollama kept" || bad "User wrong"
grep -q "^Group=ollama" "$SB/ollama.service" && ok "Group=ollama kept" || bad "Group wrong"
grep -qF "$PATH_LINE" "$SB/ollama.service" && ok "PATH line preserved verbatim" || bad "PATH line changed"
grep -q 'EnvironmentFile' "$SB/ollama.service" && bad "unexpected EnvironmentFile" || ok "no EnvironmentFile (none existed before)"

# --------------------------------------------------------------------------
head_ "6) client_version / server_version parsing"
CV="$(client_version /usr/local/bin/ollama || true)"
[ "$CV" = "0.32.9" ] && ok "client_version(old binary) = $CV" || bad "client_version(old) = ${CV:-none}"
CV2="$(client_version /tmp/opencode/ollama-new/bin/ollama || true)"
[ "$CV2" = "0.40.8" ] && ok "client_version(new binary) = $CV2" || bad "client_version(new) = ${CV2:-none}"
SV="$(server_version || true)"
[ -n "$SV" ] && ok "server_version() = $SV" || bad "server_version() empty"

# --------------------------------------------------------------------------
head_ "7) staging extract from the real tarball (no root)"
STAGE="$SB/stage"; mkdir -p "$STAGE"
zstd -dc /tmp/opencode/ollama-linux-amd64.tar.zst | tar -xf - -C "$STAGE"
[ -x "$STAGE/bin/ollama" ] && ok "staged bin/ollama present" || bad "staged bin missing"
[ -d "$STAGE/lib/ollama" ] && ok "staged lib/ollama present" || bad "staged lib missing"
[ -f "$STAGE/lib/ollama/llama-server" ] && ok "llama-server present" || bad "llama-server missing"
[ -f "$STAGE/lib/ollama/llama-quantize" ] && ok "llama-quantize present" || bad "llama-quantize missing"
[ -d "$STAGE/lib/ollama/cuda_v12" ] && ok "cuda_v12 present" || bad "cuda_v12 missing"
[ -d "$STAGE/lib/ollama/cuda_v13" ] && ok "cuda_v13 present" || bad "cuda_v13 missing"
[ -d "$STAGE/lib/ollama/vulkan" ] && ok "vulkan present" || bad "vulkan missing"
# the staged tree must be identical to the pre-extracted copy
if diff -r --no-dereference "$STAGE" /tmp/opencode/ollama-new >/dev/null 2>&1; then
  ok "staged tree == /tmp/opencode/ollama-new (byte-identical)"
else
  bad "staged tree differs from /tmp/opencode/ollama-new"
  diff -r --no-dereference "$STAGE" /tmp/opencode/ollama-new | head -10 || true
fi
echo "      staged size: $(du -sh "$STAGE" | cut -f1)"

# --------------------------------------------------------------------------
head_ "8) pre-flight serve test from the staged tree (port 11499, empty store)"
PF="$SB/pf-models"; mkdir -p "$PF"
OLLAMA_HOST=127.0.0.1:11499 OLLAMA_MODELS="$PF" OLLAMA_NO_CLOUD=1 \
  "$STAGE/bin/ollama" serve >"$SB/pf.log" 2>&1 &
PF_PID=$!
sleep 7
PV="$(curl -fsS --max-time 5 http://127.0.0.1:11499/api/version 2>/dev/null | grep -oE '"version":"[^"]+"' | cut -d'"' -f4 || true)"
kill "$PF_PID" 2>/dev/null || true; sleep 1; kill -9 "$PF_PID" 2>/dev/null || true
[ "$PV" = "0.40.8" ] && ok "staged build serves 0.40.8 (GPU+libs load OK)" || { bad "staged build served '${PV:-none}'"; tail -20 "$SB/pf.log" | sed 's/^/      /'; }
grep -q 'inference compute' "$SB/pf.log" && ok "GPU (CUDA) discovered by the staged build" || bad "no GPU discovery line in pre-flight log"

head_ "9) rootless instance untouched during the whole harness"
curl -fsS --max-time 5 http://127.0.0.1:11435/api/version >/dev/null 2>&1 \
  && ok "rootless still serving on 11435" || bad "rootless not answering on 11435"

# --------------------------------------------------------------------------
head_ "10) rollback path (sandboxed, systemctl stubbed)"
for fn in do_rollback write_unit_file snapshot_models count_matches client_version; do
  body="$(extract_fn "$fn")"
  printf '%s\n' "$body" >> "$FUNCFILE"
done
# shellcheck disable=SC1090
source "$FUNCFILE"

systemctl() { printf '      [stub] systemctl %s\n' "$*" >> "$SB/systemctl.log"; return 0; }

SB_ROOT="$SB/rollbacktest"
rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT/usr/local/bin" "$SB_ROOT/usr/local/lib/ollama" "$SB_ROOT/etc/systemd/system"
LIB_DIR="$SB_ROOT/usr/local/lib/ollama"
BIN_PATH="$SB_ROOT/usr/local/bin/ollama"
UNIT_PATH="$SB_ROOT/etc/systemd/system/ollama.service"
NOPRUNE_DROPIN="$SB_ROOT/etc/systemd/system/ollama.service.d/10-noprune-first-boot.conf"
DROPIN_DIR="$SB_ROOT/etc/systemd/system/ollama.service.d"
SYSTEM_SERVICE="ollama"
BACKUP_DIR="$SB_ROOT/backup"
mkdir -p "$BACKUP_DIR"
# simulate the state right after a failed upgrade
printf 'NEW-0.40.8-binary\n' > "$BIN_PATH"
printf 'new lib content\n' > "$LIB_DIR/libggml.so.0.27.0"
printf 'NEW UNIT\n' > "$UNIT_PATH"
printf 'OLD-0.32.9-binary\n' > "$BACKUP_DIR/ollama.bin"
mkdir -p "$BACKUP_DIR/lib-ollama-old"
printf 'old lib content\n' > "$BACKUP_DIR/lib-ollama-old/libggml.so.0.19.0"
printf 'OLD UNIT\n' > "$BACKUP_DIR/ollama.service"
mkdir -p "$DROPIN_DIR"; printf 'x\n' > "$NOPRUNE_DROPIN"

do_rollback "$BACKUP_DIR" >/dev/null 2>&1 || true
grep -q 'OLD-0.32.9-binary' "$BIN_PATH" && ok "rollback restored the old binary" || bad "binary not restored"
grep -q 'old lib content' "$LIB_DIR/libggml.so.0.19.0" 2>/dev/null && ok "rollback restored the old libs" || bad "libs not restored"
[ ! -e "$LIB_DIR/libggml.so.0.27.0" ] && ok "rollback removed the new libs" || bad "new libs still present"
grep -q 'OLD UNIT' "$UNIT_PATH" && ok "rollback restored the old unit" || bad "unit not restored"
[ ! -e "$NOPRUNE_DROPIN" ] && ok "rollback removed the no-prune drop-in" || bad "drop-in still present"
grep -q 'systemctl start ollama' "$SB/systemctl.log" && ok "rollback restarted the service" || bad "service not restarted"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
