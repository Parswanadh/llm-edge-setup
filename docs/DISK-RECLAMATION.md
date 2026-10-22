# Disk reclamation report

**Result: 33 GiB → 100.5 GiB free (97 % → 89 %). 67.6 GiB reclaimed with zero data loss.**

---

## What was deleted — regenerable caches only

| Path | Before | After | Freed | What it is |
|---|---|---|---|---|
| `~/.cache/huggingface/hub` | 50 G | 16 M | **47.0 G** | 32 model/dataset repos, re-downloadable from HF |
| `~/.npm/_cacache` | 14.2 G | 100 K | 14.2 G | npm tarball cache |
| `~/.npm/_npx` (stale dirs) | 3.8 G | 677 M | 3.1 G | temp npx installs >14 d old |
| `~/.cache/pip` | 1.5 G | 128 K | 1.5 G | pip wheel cache |
| `~/.cache/uv` | 1.4 G | 0 | 1.3 G | uv wheel cache |
| `~/.cache/go-build` | 158 M | 0 | 158 M | Go build cache |
| pnpm store | 234 M | 4 K | 161 M | pnpm content store |
| stale playwright chromium | 20 M | — | 20 M | browser build |

**Safety checks performed before deleting:**
- `lsof` on every cache tree → no process held a file open.
- No container mounted any HF cache (`HF_HOME` empty in all 14 running containers).
- Only `_npx/4ed68bd1cad489d9` was live (2 `gsd-mcp-server` processes) — **preserved**,
  confirmed by a full `/proc/*/cmdline` scan.

### HF re-download is seamless
`~/.cache/huggingface/token` is intact (37 B, mode 600), so **gated** repos re-fetch
with your existing credentials:

```bash
hf download <repo_id> --local-dir <dest>
```

22 HF hub entries survived, including `models--prism-ml--Bonsai-27B-gguf` (the model
behind the `bonsai-27b-1bit` Ollama entry), the PaddleOCR family, and the Z-Image-Turbo
set.

---

## What was deliberately NOT touched

```
~/.codex                        11 G   all 16 releases; current -> 0.163.0
~/opencode-safety-backup        25 G   the opencode recovery path (manifest.sha256,
                                       verify-opencode.sh, live-opencode.db,
                                       state/config tgz, opencode-1.18.34.bin)
~/Downloads                     14 G   Win11_25H2 ISO is 7.9 G of this
~/.local/share/opencode         20 G   opencode.db = 15,777,329,152 bytes (session history)
/usr/share/ollama/.ollama/models 31 G  shared model store
~/node_modules                  4.7 G
~/.npm/_prebuilds, _libvips, _logs
```

---

## Docker.raw forensics (read-only, not deleted)

`~/.docker/desktop/vms/0/data/Docker.raw` — 937 GiB apparent / **93 G actual**, already
fully sparse (3545 data regions, no holes to punch).

Method: loop-mounted read-only (`losetup -r -o 1048576`, UUID `a719e5e1-…` verified
against the on-disk superblock), `mount -o ro,noload`, `e2fsck -fn`:
`1461742/61399040 files, 22480643/245572864 blocks` → **92.08 GB used**.

Contents: `desktop-containerd/daemon` = 68 G
- `io.containerd.snapshotter.v1.overlayfs` = 52 G (529 snapshots)
- `io.containerd.content.v1.content` = 17 G (859 blobs)
- `docker/volumes` = 1.8 G, `docker/containers` = 19 M

Last written 2026-09-06/08. This is **Docker Desktop's own store**, separate from the
native daemon's 54.9 GB in `/var/lib/docker` — so removing it loses only Desktop-era
images, not the containers currently running. It is real data, so it was left for
explicit approval.

### Tier-2 commands (need sudo)
```bash
sudo apt remove --purge docker-desktop   # then:
rm -rf ~/.docker/desktop                 # frees 93 G
sudo apt clean && sudo rm -rf /var/lib/apt/lists/*
```

---

## Container/volume report — nothing deleted

**19 exited containers** (1.7 G), abandoned test stacks:
`ragz-preview-20260919-*` (6), `ragz-mqr-local-test-*` (5), `ragz-e2e-postgres-1`,
`ragz-response-cache-1`, `rag-agno-loopback-gateway-1`, `busy_snyder`,
`determined_ardinghelli`, `zen_easley`, `keen_nobel`, `oracle-free`
(its `oracle-data` volume is 12.69 GB).

**7 zero-link volumes** (524 M):
`ragflow-bench-native-20260823_{mysql,redis,minio}_data`,
`ragflow-swap-bench-20260823_{mysql,redis,minio}_data`,
`ragz-matrix-gateway-20260824_pgdata`.

---

## Tier-3 items needing your review

| Item | Size | Note |
|---|---|---|
| `~/.codex/packages/standalone/releases` | 5.4 G | 16 releases; older ones ≈4.6 G reclaimable, `current` → 0.163.0 |
| `~/.config/google-chrome/OptGuideOnDeviceModel` | 4.0 G | Chrome's on-device AI model, auto re-downloaded |
| `~/.config/Code/CachedExtensionVSIXs` | 909 M | VS Code installer cache |
| `~/opencode-safety-backup/2026-10-04` | 10 G | older of two snapshots |
| `~/Downloads` | 14 G | your call |

---

## Why reclamation was necessary

Disk sat at **97 % (33 GiB free)** while the 24B workload needed:
13.58 GB model download + 13.5 GB extracted copy + 1–2 GB CUDA build + 31 GB of
existing models that had to stay. Without headroom the download would have failed
mid-transfer and the builds would have filled the disk.

**Headroom now: 100.5 GiB**, leaving ~85 GiB surplus after the model and build.
