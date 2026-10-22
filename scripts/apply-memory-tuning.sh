#!/usr/bin/env bash
# apply-memory-tuning.sh — apply (or revert) the memory/swap tuning for this box.
#
#   sudo bash scripts/apply-memory-tuning.sh apply
#   sudo bash scripts/apply-memory-tuning.sh revert
#   sudo bash scripts/apply-memory-tuning.sh status
#
# WHAT IT CHANGES
#
#   1. /etc/sysctl.d/99-llm-edge-memory.conf  (the sysctl drop-in)
#   2. /etc/systemd/system/zram-memory-limit.service
#        -> sets /sys/block/zram0/mem_limit = 6G
#
# Both are reversible.  Nothing else on the box is touched; the
# `ollama-rootless` service is NOT modified.
#
# WHY
#   See systemd/MEMORY-TUNING.md.  Short version: the mmap'd model weights are
#   clean file pages that are never written to swap (so "put the model in
#   zram" cannot help and would in fact hurt — QAD-Q4_0 does not compress).
#   zram's job is to compress cold anonymous memory so the page cache has room
#   for the model.  The one real defect is that zram has no mem_limit, and
#   with vm.swappiness=180 on a 15 GiB box it can and did grow to 9.28 GiB of
#   real RAM and OOM the machine (journalctl -k, 2026-10-22 12:19:28).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYSCTL_SRC="$REPO/systemd/99-llm-edge-memory.conf"
SYSCTL_DST="/etc/sysctl.d/99-llm-edge-memory.conf"
UNIT_SRC="$REPO/systemd/zram-memory-limit.service"
UNIT_DST="/etc/systemd/system/zram-memory-limit.service"
ZRAM_MEM_LIMIT="6G"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 1
  fi
}

case "${1:-status}" in
  apply)
    need_root
    echo "==> installing $SYSCTL_DST"
    install -m 0644 "$SYSCTL_SRC" "$SYSCTL_DST"
    sysctl --system >/dev/null
    echo "==> installing $UNIT_DST"
    install -m 0644 "$UNIT_SRC" "$UNIT_DST"
    systemctl daemon-reload
    systemctl enable --now zram-memory-limit.service
    echo
    echo "applied.  verify with:"
    echo "  sysctl vm.swappiness vm.vfs_cache_pressure vm.page-cluster vm.min_free_kbytes"
    echo "  cat /sys/block/zram0/mem_limit"
    ;;

  revert)
    need_root
    echo "==> removing $SYSCTL_DST"
    rm -f "$SYSCTL_DST"
    sysctl --system >/dev/null
    echo "==> disabling $UNIT_DST"
    systemctl disable --now zram-memory-limit.service || true
    rm -f "$UNIT_DST"
    systemctl daemon-reload
    echo "==> restoring zram mem_limit to unlimited"
    sh -c 'echo 0 > /sys/block/zram0/mem_limit' || true
    echo
    echo "reverted.  the pre-existing /etc/sysctl.d/99-vm-zram-parameters.conf"
    echo "(swappiness 180, vfs_cache_pressure 50, page-cluster 0) was left alone."
    ;;

  status)
    echo "--- swap ---"
    swapon --show
    echo
    echo "--- zram ---"
    zramctl
    echo "  disksize : $(cat /sys/block/zram0/disksize) bytes"
    echo "  mem_limit: $(cat /sys/block/zram0/mem_limit) bytes  (0 = unlimited)"
    echo "  mm_stat  : $(cat /sys/block/zram0/mm_stat)"
    echo
    echo "--- sysctls ---"
    sysctl vm.swappiness vm.vfs_cache_pressure vm.page-cluster \
           vm.min_free_kbytes vm.watermark_scale_factor vm.watermark_boost_factor 2>/dev/null
    echo
    echo "--- nvme ---"
    echo "  scheduler      : $(cat /sys/block/nvme0n1/queue/scheduler)"
    echo "  read_ahead_kb  : $(cat /sys/block/nvme0n1/queue/read_ahead_kb)"
    echo
    echo "--- memory ---"
    free -m
    echo
    echo "--- unit ---"
    systemctl is-enabled zram-memory-limit.service 2>/dev/null || echo "not installed"
    ;;

  *)
    echo "usage: $0 {apply|revert|status}" >&2
    exit 2
    ;;
esac
