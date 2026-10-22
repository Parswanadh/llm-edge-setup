#!/usr/bin/env bash
#
# upgrade-ollama.sh — upgrade the SYSTEM-WIDE Ollama from 0.32.9 to 0.40.8
#
#   * Installs from the already-downloaded official tarball
#     (/tmp/opencode/ollama-linux-amd64.tar.zst) — no 1.5 GB re-download.
#   * Preserves the 31 GB model store at /usr/share/ollama/.ollama/models
#     and its `ollama:ollama` ownership.
#   * NEVER touches the rootless instance (systemd --user unit
#     `ollama-rootless`, port 11435, store /home/parshu/.ollama/models).
#   * Idempotent: re-running on an already-upgraded box is a no-op.
#
# Usage:
#     sudo bash /tmp/opencode/upgrade-ollama.sh              # do the upgrade
#     bash   /tmp/opencode/upgrade-ollama.sh --dry-run       # plan only, no root needed
#     sudo bash /tmp/opencode/upgrade-ollama.sh --rollback    # restore 0.32.9
#
# Options:
#     --dry-run             print the plan, change nothing
#     --rollback            restore the most recent backup
#     --drop-old-lib        delete the 0.32.9 lib copy after success
#     --no-preflight-serve  skip the throwaway "does it actually serve?" test
#     --official            use the official install.sh instead (re-downloads 1.5 GB)
#     --help
#
set -Eeuo pipefail   # -E: the ERR trap is inherited by functions and subshells

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
TARGET_VERSION="0.40.8"
TARBALL="/tmp/opencode/ollama-linux-amd64.tar.zst"
PRE_EXTRACTED="/tmp/opencode/ollama-new"           # fallback source (bin/ollama + lib/ollama/)
INSTALL_SH="/tmp/opencode/install.sh"               # official installer, only with --official

INSTALL_ROOT="/usr/local"
BIN_DIR="/usr/local/bin"
BIN_PATH="/usr/local/bin/ollama"
LIB_DIR="/usr/local/lib/ollama"

UNIT_PATH="/etc/systemd/system/ollama.service"
DROPIN_DIR="/etc/systemd/system/ollama.service.d"
NOPRUNE_DROPIN="${DROPIN_DIR}/10-noprune-first-boot.conf"

SYSTEM_SERVICE="ollama"             # system unit  -> port 11434
ROOTLESS_SERVICE="ollama-rootless"  # user unit   -> port 11435  (NEVER TOUCHED)
ROOTLESS_STORE="/home/parshu/.ollama/models"       # (NEVER TOUCHED)

MODEL_STORE="/usr/share/ollama/.ollama/models"     # 31 GB — PRESERVED
OLLAMA_USER="ollama"
OLLAMA_GROUP="ollama"

BACKUP_ROOT="/var/backups/ollama-upgrades"

# --------------------------------------------------------------------------
# Globals / helpers
# --------------------------------------------------------------------------
ORIG_ARGS=("$@")
DRY_RUN=0
ROLLBACK=0
USE_OFFICIAL=0
KEEP_OLD_LIB=1
PREFLIGHT_SERVE=1
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${TS}"
CHANGES_MADE=0

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARNING: %s\033[0m\n' "$*" >&2; }

# die() must go through the same rollback path as the ERR trap, otherwise an
# explicit failure (e.g. "version mismatch") would leave a half-upgraded box.
die() {
  printf '\033[1;31m    ERROR: %s\033[0m\n' "$*" >&2
  if [ "${CHANGES_MADE:-0}" -eq 1 ] && [ "${ROLLBACK:-0}" -eq 0 ] && [ "${ROLLBACK_IN_PROGRESS:-0}" -eq 0 ]; then
    warn "Rolling back automatically..."
    do_rollback "$BACKUP_DIR" || warn "Automatic rollback failed — inspect ${BACKUP_DIR}"
  fi
  exit 1
}

count_matches() { grep -c -- "$1" || true; }

# `ollama --version` reports the SERVER version when a server is reachable;
# point it at a dead port so we always read the LOCAL client version.
client_version() {
  OLLAMA_HOST="127.0.0.1:1" "$1" --version 2>&1 \
    | grep -oE 'client version is [0-9.]+' | awk '{print $NF}' | head -1 || true
}

server_version() {
  curl -fsS --max-time 5 http://127.0.0.1:11434/api/version 2>/dev/null \
    | grep -oE '"version":"[^"]+"' | cut -d'"' -f4 || true
}

# --------------------------------------------------------------------------
# Model-store snapshot (integrity baseline)
# --------------------------------------------------------------------------
snapshot_models() {
  local out="$1"
  {
    echo "# manifests"
    find "$MODEL_STORE/manifests" -type f -printf '%P\t%s\n' 2>/dev/null | sort
    echo "# blobs"
    find "$MODEL_STORE/blobs" -type f -printf '%P\t%s\n' 2>/dev/null | sort
  } > "$out"
}

# --------------------------------------------------------------------------
# systemd unit generation (kept in a function so it can be unit-tested)
# --------------------------------------------------------------------------
write_unit_file() {
  local unit_path="$1" bin_path="$2" model_store="$3" path_line="$4"
  cat > "$unit_path" <<EOF
[Unit]
Description=Ollama Service
After=network-online.target

[Service]
ExecStart=${bin_path} serve
User=${OLLAMA_USER}
Group=${OLLAMA_GROUP}
Restart=always
RestartSec=3
${path_line}
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=${model_store}"

[Install]
WantedBy=default.target
EOF
}

# --------------------------------------------------------------------------
# Rollback
# --------------------------------------------------------------------------
do_rollback() {
  local dir="${1:-}"
  ROLLBACK_IN_PROGRESS=1     # set first: die() below must not re-enter rollback
  if [ -z "$dir" ]; then
    dir="$(ls -1dt "${BACKUP_ROOT}"/*/ 2>/dev/null | head -1 || true)"
    [ -n "$dir" ] || die "no backups found under ${BACKUP_ROOT}"
    dir="${dir%/}"
  fi
  [ -d "$dir" ] || die "backup dir not found: $dir"
  log "Rolling back using backup: $dir"

  systemctl stop "$SYSTEM_SERVICE" || true

  if [ -d "$dir/lib-ollama-old" ]; then
    rm -rf "$LIB_DIR"
    if ! mv "$dir/lib-ollama-old" "$LIB_DIR"; then
      cp -a "$dir/lib-ollama-old" "$LIB_DIR"    # cross-device fallback
    fi
    info "restored ${LIB_DIR} (0.32.9)"
  fi
  if [ -f "$dir/ollama.bin" ]; then
    cp -a "$dir/ollama.bin" "$BIN_PATH"
    info "restored ${BIN_PATH}"
  fi
  if [ -f "$dir/ollama.service" ]; then
    cp -a "$dir/ollama.service" "$UNIT_PATH"
    info "restored ${UNIT_PATH}"
  fi
  rm -f "$NOPRUNE_DROPIN"
  rmdir "$DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable "$SYSTEM_SERVICE"
  systemctl start "$SYSTEM_SERVICE"
  sleep 3
  info "client version now: $(client_version "$BIN_PATH" || echo unknown)"
}

on_error() {
  local rc=$?
  if [ "${ROLLBACK_IN_PROGRESS:-0}" -eq 1 ]; then
    exit "$rc"          # already inside the rollback path — do not recurse
  fi
  if [ "${CHANGES_MADE:-0}" -eq 1 ] && [ "${ROLLBACK:-0}" -eq 0 ]; then
    warn "Upgrade failed (exit ${rc}). Rolling back automatically..."
    ROLLBACK_IN_PROGRESS=1
    do_rollback "$BACKUP_DIR" || warn "Automatic rollback failed — inspect ${BACKUP_DIR}"
  fi
  exit "$rc"
}
trap on_error ERR

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)            DRY_RUN=1 ;;
    --rollback)           ROLLBACK=1 ;;
    --keep-old-lib)       KEEP_OLD_LIB=1 ;;
    --drop-old-lib)       KEEP_OLD_LIB=0 ;;
    --no-preflight-serve) PREFLIGHT_SERVE=0 ;;
    --official)           USE_OFFICIAL=1 ;;
    -h|--help)            sed -n '2,28p' "$0"; exit 0 ;;
    *)                    die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "must be run as root (or via sudo)"
    log "Re-running under sudo (you will be asked for your password)..."
    sudo -v
    exec sudo --preserve-env=PATH "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  fi
}

# ==========================================================================
#  DRY RUN  (read-only plan)
# ==========================================================================
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY RUN — nothing will be changed"
  info "current binary     : ${BIN_PATH}"
  info "current client ver : $(client_version "$BIN_PATH" || echo unknown)"
  info "current server ver : $(server_version || echo unknown) (port 11434)"
  info "model store        : ${MODEL_STORE} ($(du -sh "$MODEL_STORE" 2>/dev/null | cut -f1)) — PRESERVED"
  info "rootless instance  : ${ROOTLESS_SERVICE} on 11435 — NOT touched"
  if [ -f "$TARBALL" ]; then
    info "install source     : tarball ${TARBALL} ($(du -h "$TARBALL" | cut -f1))"
  elif [ -x "${PRE_EXTRACTED}/bin/ollama" ]; then
    info "install source     : pre-extracted ${PRE_EXTRACTED}"
  else
    warn "no install source found (need ${TARBALL} or ${PRE_EXTRACTED})"
  fi
  info "free space on /     : $(df -h "$INSTALL_ROOT" | awk 'NR==2{print $4}')"
  info "backup dir would be : ${BACKUP_DIR}"
  cat <<'EOF'

    plan:
      1. back up  /usr/local/bin/ollama  and  /etc/systemd/system/ollama.service
      2. move     /usr/local/lib/ollama  ->  <backup>/lib-ollama-old   (instant, same fs)
      3. extract  the 0.40.8 tarball to a staging dir, then rename into place
      4. rewrite  the unit (same ExecStart/User/Group, PATH preserved verbatim,
                  plus explicit OLLAMA_HOST=127.0.0.1:11434 and
                  OLLAMA_MODELS=/usr/share/ollama/.ollama/models)
      5. first start with OLLAMA_NOPRUNE=1 (temporary drop-in), verify the
         model store is byte-identical, then remove the drop-in and restart
      6. verify  /api/version == 0.40.8 on 11434, models still listed
      7. leave   ollama-rootless (11435) and /home/parshu/.ollama/models alone

EOF
  exit 0
fi

need_root

if [ "$ROLLBACK" -eq 1 ]; then
  do_rollback
  exit 0
fi

# ==========================================================================
#  UPGRADE
# ==========================================================================
log "Ollama system upgrade: 0.32.9 -> ${TARGET_VERSION}"
info "install root : ${INSTALL_ROOT}   (binary: ${BIN_PATH})"
info "model store  : ${MODEL_STORE}   (PRESERVED, never modified)"
info "rootless     : ${ROOTLESS_SERVICE} on 11435 — NOT touched by this script"
info "backup dir   : ${BACKUP_DIR}"

# --- 1. Preflight ---------------------------------------------------------
log "1/9  Preflight checks"

[ -d "$MODEL_STORE" ] || die "model store not found: ${MODEL_STORE}"
[ -x "$BIN_PATH" ]    || die "current ollama binary not found: ${BIN_PATH}"

CURRENT_CLIENT_VERSION="$(client_version "$BIN_PATH" || true)"
CURRENT_SERVER_VERSION="$(server_version || true)"
info "current client version : ${CURRENT_CLIENT_VERSION:-unknown}"
info "current server version : ${CURRENT_SERVER_VERSION:-unknown} (port 11434)"

if [ "${CURRENT_CLIENT_VERSION:-}" = "$TARGET_VERSION" ]; then
  info "already at ${TARGET_VERSION} — nothing to do (idempotent no-op)."
  exit 0
fi

SRC=""
if [ "$USE_OFFICIAL" -eq 1 ]; then
  [ -x "$INSTALL_SH" ] || die "official installer not found: ${INSTALL_SH}"
  SRC="official"
elif [ -f "$TARBALL" ]; then
  SRC="tarball"
elif [ -x "${PRE_EXTRACTED}/bin/ollama" ]; then
  SRC="pre-extracted"
else
  die "no source for the new build (need ${TARBALL} or ${PRE_EXTRACTED})"
fi
info "install source         : ${SRC}"

AVAIL_BYTES="$(df -PB1 "$INSTALL_ROOT" | awk 'NR==2{print $4}')"
NEED_BYTES=$(( 3 * 1024 * 1024 * 1024 ))
if [ "$AVAIL_BYTES" -lt "$NEED_BYTES" ]; then
  die "not enough free space on ${INSTALL_ROOT}: need ~3 GiB, have $((AVAIL_BYTES/1024/1024)) MiB"
fi
info "free space             : $(df -h "$INSTALL_ROOT" | awk 'NR==2{print $4}') free on $(df -h "$INSTALL_ROOT" | awk 'NR==2{print $6}')"

if [ "$SRC" != "official" ] && [ -x "${PRE_EXTRACTED}/bin/ollama" ]; then
  VC="$(client_version "${PRE_EXTRACTED}/bin/ollama" || true)"
  [ "$VC" = "$TARGET_VERSION" ] || die "pre-extracted binary reports '${VC:-unknown}', expected ${TARGET_VERSION}"
  info "new binary self-check : client version ${VC} OK"
fi

# --- 2. Snapshot the model store -----------------------------------------
log "2/9  Snapshotting the model store (integrity baseline)"
mkdir -p "$BACKUP_DIR"
snapshot_models "$BACKUP_DIR/models-before.txt"
BEFORE_MANIFESTS="$(count_matches 'registry' < "$BACKUP_DIR/models-before.txt")"
BEFORE_BLOBS="$(count_matches 'sha256-' < "$BACKUP_DIR/models-before.txt")"
info "manifests: ${BEFORE_MANIFESTS}   blobs: ${BEFORE_BLOBS}   size: $(du -sh "$MODEL_STORE" | cut -f1)"
info "top-level entries in the store:"; ls -A "$MODEL_STORE" | sed 's/^/      /'
info "baseline written to ${BACKUP_DIR}/models-before.txt"

# --- 3. Back up binary + unit --------------------------------------------
log "3/9  Backing up the current binary and systemd unit"
cp -a "$BIN_PATH"  "$BACKUP_DIR/ollama.bin"
cp -a "$UNIT_PATH" "$BACKUP_DIR/ollama.service"
info "binary -> ${BACKUP_DIR}/ollama.bin"
info "unit   -> ${BACKUP_DIR}/ollama.service"

# --- 4. Stop the SYSTEM service only -------------------------------------
log "4/9  Stopping the system-wide service (ollama.service on 11434)"
info "NOTE: ollama-rootless (11435) is deliberately left running."
systemctl stop "$SYSTEM_SERVICE"
CHANGES_MADE=1
info "system service stopped"

# --- 5. Install the new bits ---------------------------------------------
log "5/9  Installing ${TARGET_VERSION}"
STAGE="${INSTALL_ROOT}/.ollama-stage-${TS}"
rm -rf "$STAGE"; mkdir -p "$STAGE"
SWAP_NEEDED=1

if [ "$SRC" = "official" ]; then
  if [ -f "$TARBALL" ]; then
    info "official mode, but a local official tarball exists — using it (no re-download)"
    zstd -dc "$TARBALL" | tar -xf - -C "$STAGE"
  else
    info "running the official installer: ${INSTALL_SH}"
    info "(this re-downloads ~1.5 GB and rewrites /etc/systemd/system/ollama.service)"
    sh "$INSTALL_SH"
    SWAP_NEEDED=0
  fi
elif [ "$SRC" = "tarball" ]; then
  info "extracting ${TARBALL} -> ${STAGE}"
  zstd -dc "$TARBALL" | tar -xf - -C "$STAGE"
else
  info "copying pre-extracted tree ${PRE_EXTRACTED} -> ${STAGE}"
  cp -a "${PRE_EXTRACTED}/." "$STAGE/"
fi

if [ "$SWAP_NEEDED" -eq 1 ]; then
  [ -x "${STAGE}/bin/ollama" ]  || die "staged binary missing: ${STAGE}/bin/ollama"
  [ -d "${STAGE}/lib/ollama" ]  || die "staged lib dir missing: ${STAGE}/lib/ollama"
  info "staged: $(du -sh "$STAGE" | cut -f1)"

  # pre-flight: does the staged build actually serve?
  if [ "$PREFLIGHT_SERVE" -eq 1 ]; then
    info "pre-flight serve test on 127.0.0.1:11499 (temp empty model dir, no GPU work)"
    PF_MODELS="$(mktemp -d /tmp/ollama-preflight-XXXXXX)"
    PF_LOG="/tmp/ollama-preflight-${TS}.log"
    PF_PID="/tmp/ollama-preflight-${TS}.pid"
    # Run in a subshell with the ERR trap disabled: a failing throwaway
    # server must never trigger the rollback path.
    ( trap - ERR; set +e
      exec env OLLAMA_HOST=127.0.0.1:11499 OLLAMA_MODELS="$PF_MODELS" OLLAMA_NO_CLOUD=1 \
        "${STAGE}/bin/ollama" serve >"$PF_LOG" 2>&1 ) &
    PF_PID_VAL=$!
    echo "$PF_PID_VAL" > "$PF_PID"
    sleep 6
    PV="$(curl -fsS --max-time 5 http://127.0.0.1:11499/api/version 2>/dev/null | grep -oE '"version":"[^"]+"' | cut -d'"' -f4 || true)"
    kill "$PF_PID_VAL" 2>/dev/null || true
    sleep 1
    kill -9 "$PF_PID_VAL" 2>/dev/null || true
    rm -rf "$PF_MODELS"
    if [ "$PV" = "$TARGET_VERSION" ]; then
      info "pre-flight serve OK (reported ${PV})"
    else
      warn "pre-flight serve did not report ${TARGET_VERSION} (got '${PV:-none}')"
      warn "log: ${PF_LOG}"
    fi
  fi

  # swap into place
  log "6/9  Swapping into ${INSTALL_ROOT}"
  if [ -d "$LIB_DIR" ]; then
    if [ "$(stat -c %d "$LIB_DIR")" = "$(stat -c %d "$BACKUP_DIR")" ]; then
      mv "$LIB_DIR" "${BACKUP_DIR}/lib-ollama-old"       # same fs -> instant
    else
      cp -a "$LIB_DIR" "${BACKUP_DIR}/lib-ollama-old"
      rm -rf "$LIB_DIR"
    fi
    info "old 0.32.9 libs set aside -> ${BACKUP_DIR}/lib-ollama-old (rollback copy)"
  fi
  mkdir -p "$INSTALL_ROOT/lib" "$BIN_DIR"
  mv "${STAGE}/lib/ollama" "$LIB_DIR"
  mv "${STAGE}/bin/ollama"  "$BIN_PATH"
  chown -R root:root "$LIB_DIR" "$BIN_PATH"
  chmod 755 "$BIN_PATH"
  find "$LIB_DIR" -type d -exec chmod 755 {} +
  chmod -R a+r "$LIB_DIR"
  rm -rf "$STAGE"
  info "installed $(du -sh "$LIB_DIR" | cut -f1) of libs + $(du -h "$BIN_PATH" | cut -f1) binary"
else
  log "6/9  Files already installed by the official installer"
fi

NEW_CLIENT_VERSION="$(client_version "$BIN_PATH" || true)"
[ "$NEW_CLIENT_VERSION" = "$TARGET_VERSION" ] \
  || die "post-install client version is '${NEW_CLIENT_VERSION:-unknown}', expected ${TARGET_VERSION}"
info "client version verified: ${NEW_CLIENT_VERSION}"

# --- 7. systemd unit ------------------------------------------------------
log "7/9  Refreshing the systemd unit"
info "existing unit backed up at ${BACKUP_DIR}/ollama.service"

# Keep the existing unit semantics; add ONLY explicit, provably-identical
# settings so the model store path does not depend on $HOME resolution:
#   OLLAMA_MODELS=/usr/share/ollama/.ollama/models
#       <- the value the current unit already resolves to (journal shows
#          "server config" ... OLLAMA_MODELS:/usr/share/ollama/.ollama/models)
#   OLLAMA_HOST=127.0.0.1:11434  -> explicit, never bind 0.0.0.0
# The PATH line of the existing unit is preserved verbatim.
PATH_LINE="$(grep -m1 '^Environment="PATH=' "$BACKUP_DIR/ollama.service" || true)"
if [ -z "$PATH_LINE" ]; then
  PATH_LINE='Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
  warn "no PATH line found in the old unit; using a minimal one"
fi

write_unit_file "$UNIT_PATH" "$BIN_PATH" "$MODEL_STORE" "$PATH_LINE"
chown root:root "$UNIT_PATH"; chmod 644 "$UNIT_PATH"
info "unit written (model store pinned explicitly, PATH preserved)"

# First boot with pruning disabled, so 0.40.8 cannot delete any legacy blob
# it does not recognise. Removed again after verification.
mkdir -p "$DROPIN_DIR"
cat > "$NOPRUNE_DROPIN" <<EOF
[Service]
# TEMPORARY: first boot of ${TARGET_VERSION} — do not prune any blob.
Environment=OLLAMA_NOPRUNE=1
EOF
info "temporary no-prune drop-in created (removed after verification)"

systemctl daemon-reload
systemctl enable "$SYSTEM_SERVICE"

# --- 8. Start + verify ----------------------------------------------------
log "8/9  Starting the system-wide service"
systemctl start "$SYSTEM_SERVICE"
sleep 5
if ! systemctl is-active --quiet "$SYSTEM_SERVICE"; then
  systemctl status "$SYSTEM_SERVICE" --no-pager -n 30 || true
  die "ollama.service failed to start"
fi
info "ollama.service is active"

SV="$(server_version || true)"
info "server reports version: ${SV:-unknown}"
[ "$SV" = "$TARGET_VERSION" ] || die "server on 11434 reports '${SV:-unknown}', expected ${TARGET_VERSION}"

MODEL_COUNT="$(curl -fsS --max-time 15 http://127.0.0.1:11434/api/tags | grep -oE '"name":"[^"]+"' | wc -l || true)"
info "models visible on 11434: ${MODEL_COUNT} (manifests before: ${BEFORE_MANIFESTS})"

snapshot_models "$BACKUP_DIR/models-after.txt"
if diff -q "$BACKUP_DIR/models-before.txt" "$BACKUP_DIR/models-after.txt" >/dev/null 2>&1; then
  info "model store byte-identical (every manifest + blob unchanged)"
else
  warn "model store CHANGED — diff:"
  diff "$BACKUP_DIR/models-before.txt" "$BACKUP_DIR/models-after.txt" | head -40 || true
  die "model store integrity check failed"
fi

journalctl -u "$SYSTEM_SERVICE" --no-pager -n 60 \
  | grep -E 'inference compute|discovering available GPUs|unused blobs|Listening on' | tail -4 | sed 's/^/    /' || true

# --- 9. Cleanup + final checks -------------------------------------------
log "9/9  Cleanup and final checks"
rm -f "$NOPRUNE_DROPIN"
rmdir "$DROPIN_DIR" 2>/dev/null || true
systemctl daemon-reload
systemctl restart "$SYSTEM_SERVICE"
sleep 4
systemctl is-active --quiet "$SYSTEM_SERVICE" || die "ollama.service failed to restart after drop-in removal"
info "no-prune drop-in removed; service restarted clean"

if [ "$KEEP_OLD_LIB" -eq 1 ]; then
  info "old 0.32.9 libs kept for rollback: ${BACKUP_DIR}/lib-ollama-old"
  info "  free them later with: rm -rf ${BACKUP_DIR}/lib-ollama-old"
else
  rm -rf "${BACKUP_DIR}/lib-ollama-old"
  info "old 0.32.9 libs removed"
fi

# the rootless instance must be untouched
if pgrep -u "$(id -u parshu)" -f 'ollama serve' >/dev/null 2>&1; then
  info "ollama-rootless process still running (untouched)"
else
  warn "no rootless 'ollama serve' process found for uid $(id -u parshu)"
fi
ROOTLESS_MODELS="$(curl -fsS --max-time 5 http://127.0.0.1:11435/api/tags 2>/dev/null | grep -oE '"name":"[^"]+"' | wc -l || true)"
info "ollama-rootless models still listed on 11435: ${ROOTLESS_MODELS}"

log "UPGRADE COMPLETE"
cat <<EOF

    system-wide ollama : ${TARGET_VERSION}   (port 11434, store ${MODEL_STORE})
    rootless ollama    : 0.40.8             (port 11435, store ${ROOTLESS_STORE})  [untouched]
    backups            : ${BACKUP_DIR}
    rollback command   : sudo bash /tmp/opencode/upgrade-ollama.sh --rollback

    client usage:
      system   : ollama run <model>                        # default host 127.0.0.1:11434
      rootless : OLLAMA_HOST=127.0.0.1:11435 ollama run <model>

EOF
