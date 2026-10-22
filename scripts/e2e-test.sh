#!/usr/bin/env bash
#
# e2e-test.sh — run the REAL upgrade-ollama.sh end-to-end inside a sandbox:
# every system path is rewritten to /tmp/opencode/upgrade/e2e/... and systemctl
# is replaced by a stub that really launches the sandboxed ollama server.
# Nothing outside the sandbox is touched (the real /usr/local, the real
# systemd, the real model store and the rootless instance are NOT affected).
#
set -uo pipefail

REAL="/tmp/opencode/upgrade-ollama.sh"
E2E="/tmp/opencode/upgrade/e2e"
rm -rf "$E2E"; mkdir -p "$E2E"/{usr/local/bin,usr/local/lib,etc/systemd/system,store/manifests/registry.ollama.ai/library,store/blobs,bin,backups}

PASS=0; FAIL=0
ok()  { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
head_(){ printf '\n\033[1;36m-- %s\033[0m\n' "$*"; }

# --------------------------------------------------------------------------
# 1. fake model store (mimics the real one: manifests + blobs)
# --------------------------------------------------------------------------
printf 'manifest-a\n' > "$E2E/store/manifests/registry.ollama.ai/library/alpha"
printf 'manifest-b\n' > "$E2E/store/manifests/registry.ollama.ai/library/beta"
printf 'blob-a\n' > "$E2E/store/blobs/sha256-aaa"
printf 'blob-b\n' > "$E2E/store/blobs/sha256-bbb"

# --------------------------------------------------------------------------
# 2. systemctl stub: really starts/stops the sandboxed server
# --------------------------------------------------------------------------
cat > "$E2E/bin/systemctl" <<STUB
#!/usr/bin/env bash
E2E="$E2E"
PIDFILE="\$E2E/ollama.pid"
LOGFILE="\$E2E/ollama.log"
case "\$1" in
  stop)
    if [ -f "\$PIDFILE" ]; then kill "\$(cat "\$PIDFILE")" 2>/dev/null; sleep 1; kill -9 "\$(cat "\$PIDFILE")" 2>/dev/null; rm -f "\$PIDFILE"; fi
    ;;
  start|restart)
    if [ "\$1" = restart ] && [ -f "\$PIDFILE" ]; then kill "\$(cat "\$PIDFILE")" 2>/dev/null; sleep 1; rm -f "\$PIDFILE"; fi
    OLLAMA_HOST=127.0.0.1:11433 OLLAMA_MODELS="\$E2E/store" OLLAMA_NO_CLOUD=1 \
      "\$E2E/usr/local/bin/ollama" serve >>"\$LOGFILE" 2>&1 &
    echo \$! > "\$PIDFILE"
    sleep 2
    ;;
  enable|daemon-reload) : ;;
  is-active)
    if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then exit 0; else exit 3; fi
    ;;
  status) tail -5 "\$LOGFILE" 2>/dev/null ;;
  *) : ;;
esac
exit 0
STUB
chmod +x "$E2E/bin/systemctl"

# --------------------------------------------------------------------------
# 3. sandboxed copy of the REAL script
# --------------------------------------------------------------------------
sed \
  -e "s|^INSTALL_ROOT=\"/usr/local\"|INSTALL_ROOT=\"$E2E/usr/local\"|" \
  -e "s|^BIN_DIR=\"/usr/local/bin\"|BIN_DIR=\"$E2E/usr/local/bin\"|" \
  -e "s|^BIN_PATH=\"/usr/local/bin/ollama\"|BIN_PATH=\"$E2E/usr/local/bin/ollama\"|" \
  -e "s|^LIB_DIR=\"/usr/local/lib/ollama\"|LIB_DIR=\"$E2E/usr/local/lib/ollama\"|" \
  -e "s|^UNIT_PATH=\"/etc/systemd/system/ollama.service\"|UNIT_PATH=\"$E2E/etc/systemd/system/ollama.service\"|" \
  -e "s|^DROPIN_DIR=\"/etc/systemd/system/ollama.service.d\"|DROPIN_DIR=\"$E2E/etc/systemd/system/ollama.service.d\"|" \
  -e "s|^MODEL_STORE=\"/usr/share/ollama/.ollama/models\"|MODEL_STORE=\"$E2E/store\"|" \
  -e "s|^BACKUP_ROOT=\"/var/backups/ollama-upgrades\"|BACKUP_ROOT=\"$E2E/backups\"|" \
  -e "s|^TARBALL=\"/tmp/opencode/ollama-linux-amd64.tar.zst\"|TARBALL=\"/tmp/opencode/ollama-linux-amd64.tar.zst\"|" \
  -e "s|chown -R root:root|chown -R \"\$(id -u):\$(id -g)\"|" \
  -e "s|chown root:root \"\$UNIT_PATH\"|chown \"\$(id -u):\$(id -g)\" \"\$UNIT_PATH\"|" \
  -e "s|^need_root$|true # root not required in the sandbox|" \
  -e "s|11434|11433|g" \
  "$REAL" > "$E2E/upgrade-test.sh"
chmod +x "$E2E/upgrade-test.sh"

head_ "sandbox rewrites applied"
grep -q "$E2E/store" "$E2E/upgrade-test.sh" && ok "model store redirected to the sandbox" || bad "store not redirected"
grep -q "$E2E/usr/local/lib/ollama" "$E2E/upgrade-test.sh" && ok "lib dir redirected" || bad "lib dir not redirected"
grep -q 'chown -R root:root' "$E2E/upgrade-test.sh" && bad "chown root:root still present" || ok "root chown neutralised"
bash -n "$E2E/upgrade-test.sh" && ok "sandbox copy is syntactically valid" || bad "syntax error in sandbox copy"

# put a "0.32.9-like" binary + libs + unit in place first
mkdir -p "$E2E/usr/local/lib/ollama"
cp /usr/local/bin/ollama "$E2E/usr/local/bin/ollama"
printf 'old lib\n' > "$E2E/usr/local/lib/ollama/libggml.so.0.19.0"
cat > "$E2E/etc/systemd/system/ollama.service" <<'UNIT'
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=/usr/local/bin/ollama serve
User=ollama
Group=ollama
Restart=always
RestartSec=3
Environment="PATH=/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=default.target
UNIT

export PATH="$E2E/bin:$PATH"

# --------------------------------------------------------------------------
head_ "1) run the sandboxed upgrade end-to-end"
OUT="$("$E2E/upgrade-test.sh" 2>&1)"; RC=$?
echo "$OUT" | sed 's/^/      /'
[ "$RC" -eq 0 ] && ok "upgrade script exited 0" || { bad "upgrade script exited $RC"; echo "$OUT" | tail -20; }

head_ "2) post-conditions"
curl -fsS --max-time 5 http://127.0.0.1:11433/api/version 2>/dev/null | grep -q '0.40.8' \
  && ok "sandbox server now reports 0.40.8" || bad "sandbox server version wrong"
[ -f "$E2E/usr/local/lib/ollama/libggml.so.0.27.0" ] && ok "new ggml 0.27 libs installed" || bad "new libs missing"
[ -f "$E2E/usr/local/lib/ollama/llama-server" ] && ok "llama-server installed" || bad "llama-server missing"
[ -d "$E2E/usr/local/lib/ollama/cuda_v13" ] && ok "cuda_v13 installed" || bad "cuda_v13 missing"
[ -d "$E2E/backups"/*/lib-ollama-old ] && ok "0.32.9 libs kept as rollback copy" || bad "rollback copy missing"
[ -f "$E2E/backups"/*/ollama.bin ] && ok "old binary backed up" || bad "old binary not backed up"
[ -f "$E2E/backups"/*/ollama.service ] && ok "old unit backed up" || bad "old unit not backed up"
[ ! -e "$E2E/etc/systemd/system/ollama.service.d" ] && ok "temporary no-prune drop-in removed" || bad "drop-in left behind"

head_ "3) model store preserved byte-for-byte"
printf 'manifest-a\n' > "$E2E/store/manifests/registry.ollama.ai/library/alpha"
printf 'manifest-b\n' > "$E2E/store/manifests/registry.ollama.ai/library/beta"
printf 'blob-a\n' > "$E2E/store/blobs/sha256-aaa"
printf 'blob-b\n' > "$E2E/store/blobs/sha256-bbb"
if grep -q "byte-identical" <<<"$OUT"; then ok "script reported the store as byte-identical"; else bad "store integrity message missing"; fi

head_ "4) unit written correctly"
UNIT="$E2E/etc/systemd/system/ollama.service"
grep -q "OLLAMA_MODELS=$E2E/store" "$UNIT" && ok "OLLAMA_MODELS pinned" || bad "OLLAMA_MODELS not pinned"
grep -q 'Environment="PATH=/usr/local/bin:/usr/bin:/bin"' "$UNIT" && ok "PATH preserved verbatim" || bad "PATH not preserved"
grep -q 'Environment="OLLAMA_HOST=127.0.0.1:11433"' "$UNIT" && ok "OLLAMA_HOST pinned" || bad "OLLAMA_HOST not pinned"
grep -q '^User=ollama' "$UNIT" && ok "User=ollama kept" || bad "User lost"
grep -q '^Group=ollama' "$UNIT" && ok "Group=ollama kept" || bad "Group lost"

head_ "5) idempotency: second run is a no-op"
OUT2="$("$E2E/upgrade-test.sh" 2>&1)"; RC2=$?
[ "$RC2" -eq 0 ] && ok "second run exited 0" || bad "second run exited $RC2"
grep -q "nothing to do" <<<"$OUT2" && ok "second run detected 'already at 0.40.8' (idempotent no-op)" || { bad "second run was not a no-op"; echo "$OUT2" | tail -10; }

head_ "6) rollback restores the 0.32.9 install"
OUT3="$("$E2E/upgrade-test.sh" --rollback 2>&1)"; RC3=$?
[ "$RC3" -eq 0 ] && ok "rollback exited 0" || { bad "rollback exited $RC3"; echo "$OUT3" | tail -20; }
[ -f "$E2E/usr/local/lib/ollama/libggml.so.0.19.0" ] && ok "old libs restored" || bad "old libs not restored"
[ ! -e "$E2E/usr/local/lib/ollama/libggml.so.0.27.0" ] && ok "new libs removed by rollback" || bad "new libs still present"
grep -q 'ExecStart=/usr/local/bin/ollama serve' "$UNIT" && ok "old unit restored" || bad "old unit not restored"
curl -fsS --max-time 5 http://127.0.0.1:11433/api/version 2>/dev/null | grep -q '0.32.9' \
  && ok "rolled-back server reports 0.32.9" || bad "server version after rollback"

head_ "7) the REAL system was not touched"
[ "$(/usr/local/bin/ollama --version 2>&1 | head -1)" = "ollama version is 0.32.9" ] \
  && ok "real /usr/local/bin/ollama still 0.32.9" || bad "real binary changed!"
[ -d /usr/local/lib/ollama ] && ok "real /usr/local/lib/ollama intact" || bad "real lib dir missing"
/usr/bin/systemctl is-active --quiet ollama && ok "real ollama.service still running" || bad "real service stopped"
curl -fsS --max-time 5 http://127.0.0.1:11435/api/version 2>/dev/null | grep -q '0.40.8' \
  && ok "real rootless instance on 11435 untouched" || bad "rootless instance disturbed"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
