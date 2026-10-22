# Memory / swap / page-cache tuning for LFM2.5-24B-A2B on this laptop

Measured on this machine on 2026-10-22. Everything below is either a command
output from this session or is explicitly tagged as a recommendation.

**TL;DR**

1. The premise "put the model in zram" is **wrong for this model**. QAD-Q4_0
   weight bytes are incompressible (measured: 64 MiB sample → 65.58 MB under
   `zstd -1`, ratio **1.02x**). zram would store them 1:1 in RAM and charge a
   decompression on every swap-in — strictly worse than leaving them in the
   page cache.
2. The mmap'd model weights are **clean, file-backed pages**. The kernel never
   writes clean file pages to swap. They live in the **page cache** or they are
   dropped and re-read from the **NVMe**. Swap configuration has *no direct*
   effect on where the model lives; it only matters indirectly, by keeping cold
   anonymous desktop memory out of real RAM so the page cache has room.
3. The current kernel configuration is already close to optimal for this
   workload (`vm.swappiness=180`, `vm.vfs_cache_pressure=50`,
   `vm.page-cluster=0`, zram at priority 100, zswap disabled, NVMe scheduler
   `none`, `read_ahead_kb=128`). The upstream llama.cpp warnings about
   `page-cluster 8192` and read-ahead do **not** apply to this box.
4. The one genuine misconfiguration is **`/dev/zram0` has no `mem_limit`**
   while `vm.swappiness=180` and the zram `disksize` is 22.7 GiB on a 15 GiB
   box. With incompressible anonymous data, zram can grow to 22.7 GiB of *real*
   RAM → straight into the OOM killer (this box has OOM-killed itself 31 times).
   Fix: `mem_limit = 6G`.
5. The dominant performance factor is **RAM headroom**, not swap tuning. The
   box has to run the desktop plus (currently) 2–4 concurrent `llama-server`
   processes. The 24B needs ~6.5 GiB of page cache for the CPU-resident
   experts. That only fits if nothing else is competing.

---

## 1. Current state (verbatim)

### Swap

```
$ swapon --show
NAME       TYPE       SIZE USED PRIO
/swap.img  file         4G   0B   -1
/dev/zram0 partition  22.7G 5.2G  100

$ cat /proc/swaps
Filename				Type		Size		Used		Priority
/swap.img                               file		4194300		0		-1
/dev/zram0                              partition	23797244	5436536		100

$ zramctl
NAME       ALGORITHM DISKSIZE DATA COMPR TOTAL STREAMS MOUNTPOINT
/dev/zram0 zstd         22.7G   5G  1.2G  1.2G         [SWAP]
```

### zram sysfs

```
$ cat /sys/block/zram0/disksize
24368381952                       # 22.7 GiB  (= ram * 1.5)
$ cat /sys/block/zram0/comp_algorithm
lzo-rle lzo lz4 lz4hc [zstd] deflate
$ cat /sys/block/zram0/mm_stat
5834031104 1376179989 1412014080 0 4913569792 39213 1205930 8848 3908015
#  orig_data_size 5.83 GB -> compr_data_size 1.38 GB -> mem_used_total 1.41 GB
#  mem_limit = 0  (UNLIMITED)   mem_used_max = 4.91 GB
#  huge_pages = 8848 (34.6 MiB stored raw/incompressible)
#  huge_pages_since = 3908015 (14.9 GB of incompressible data since boot)
$ ls -l /sys/block/zram0/mem_limit
-rw------- 1 root root 4096 ...      # root-only, mode 0400
```

### sysctls

```
$ sysctl vm.swappiness vm.vfs_cache_pressure vm.page-cluster vm.min_free_kbytes \
          vm.dirty_ratio vm.dirty_background_ratio
vm.swappiness = 180
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
vm.min_free_kbytes = 67584
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
```

These come from `/etc/sysctl.d/99-vm-zram-parameters.conf`:

```
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
```

### Boot / zswap / THP / scheduler

```
$ cat /proc/cmdline
BOOT_IMAGE=/boot/vmlinuz-7.0.0-38-generic root=UUID=f03fd834-... ro nvidia-drm.modeset=1 zswap.enabled=0 quiet splash vt.handoff=7

$ cat /sys/module/zswap/parameters/enabled      -> N
$ cat /sys/module/zswap/parameters/max_pool_percent -> 20
$ cat /sys/module/zswap/parameters/compressor    -> lzo

$ cat /sys/kernel/mm/transparent_hugepage/enabled
always [madvise] never
$ cat /sys/kernel/mm/transparent_hugepage/defrag
always defer defer+madvise [madvise] never

$ grep READ_ONLY_THP_FOR_FS /boot/config-$(uname -r)
# CONFIG_READ_ONLY_THP_FOR_FS is not set        <-- file-backed THP IMPOSSIBLE

$ cat /sys/block/nvme0n1/queue/scheduler
[none] mq-deadline                                <-- already 'none'
$ cat /sys/block/nvme0n1/queue/read_ahead_kb
128                                               <-- already the 128 KB default
```

### zram provisioning

`/etc/systemd/zram-generator.conf`:

```ini
[zram0]
zram-size = max(8192, ram * 1.5)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
```

Started by `systemd-zram-setup@zram0.service` (zram-generator 1.1.2).

### Swap priority

`zram0` is at priority **100** and `/swap.img` at **-1**, so the kernel already
prefers zram. `swapon --show` confirms it. No change needed.

### Live swap traffic (idle, other agents' servers running)

```
$ vmstat 1 10
procs -----------memory---------- ---swap-- -----io---- -system-- -------cpu-------
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st gu
 1  0 6164336 4423632  17168 6720628 8732 14300 64052 23569 46282   14  7  3 89  1  0  0
 1  0 6163616 4438492  17232 6731140  856    0  1608   248 17888 26094   5  2 93  0  0  0
 5  0 6154188 4339912  17760 6776336 10464    0 40672 27672 22145 33938  10  4 86  1  0  0
 ...
 1  0 6135696 4187672  18848 6834992 4464    0   4520 170136 17561 23333   6  2 91  1  0  0
```

`si` is 700–16 500 pages/s with `so = 0` and `swpd` falling: pages are being
**read back in from zram** while nothing is being swapped out. That is zram
decompression churn on anonymous desktop memory, not model I/O.

### iostat (NVMe)

```
$ iostat -x 1 3 | grep nvme
nvme0n1   r/s 3.00  w/s 12.00  ... await 0.33  %util 4.10
zram0     r/s 150   w/s 600    ...
```

The NVMe is **not** doing anything pathological: ~0.33 ms await, 4 % util.

### fstrim

`fstrim.timer` is **active**, weekly, next trigger Mon 2026-10-26 00:41:04 IST.
Not changed.

---

## 2. What is actually true about where the model lives

### 2a. Clean file pages are never swapped

With `--n-cpu-moe N`, the CPU-resident expert tensors are read directly out of
the model's `mmap()`. Those are **clean, file-backed** pages. Under memory
pressure the kernel's reclaim path for a clean file page is: *drop the page*.
It is **not** written to swap.

Consequence: swapping the model into zram is not something the kernel does, and
forcing it would be actively harmful (see 2b).

Verified with `/proc/<pid>/smaps` on a live `llama-server`: the model mapping
reports large `File:` and `Swap: 0`.

### 2b. QAD-Q4_0 weights are incompressible — zram cannot help them

```
$ dd if=<8B lfm2moe blob> of=/tmp/opencode/sample.bin bs=1M count=64 skip=2000
$ zstd -1 -c sample.bin | wc -c   -> 65581600   (67108864 raw)
$ zstd -3 -c sample.bin | wc -c   -> 65657468
$ zstd -9 -c sample.bin | wc -c   -> 65578777
$ gzip -6 -c sample.bin | wc -c   -> 65687371
$ xz   -3 -c sample.bin | wc -c   -> 66154564
```

64 MiB → 62.5 MiB … 63.1 MiB. **Ratio 1.02x (i.e. no compression at all, the
frame header is larger than the savings).** 4-bit quantized weights are
essentially random bits.

So if the model's 6.5 GiB of CPU-resident experts *were* swapped:

| placement | real RAM used | cost per swap-in |
|---|---|---|
| page cache | 6.5 GiB | ~100 ns (RAM) |
| zram | ~6.5 GiB (1:1, no compression) | zstd decompress of incompressible data ≈ memcpy + failed compress check |
| `/swap.img` on NVMe | ~0 GiB | ~100 µs NVMe random read |

zram is *at best* break-even against the page cache and *never* better. The
page cache is the right home for the model. zram's job on this box is to
compress the **desktop's anonymous memory** (measured 5.83 GB → 1.38 GB,
**4.2x**) so that real RAM is available for the model's page cache.

> The original hypothesis in the task brief ("~1:3 compression → ~4–5 GiB real
> RAM … this may be the single biggest win available") does not hold for
> quantized weights. The 4.2x ratio the kernel reports for zram on this box
> comes from anonymous desktop memory, not from model bytes.

### 2c. The real budget

For LFM2.5-24B-A2B (GGUF header: 40 blocks, 38 MoE layers, 64 experts,
top-4):

```
total tensor bytes   13.578 GB file  (~12.6 GiB of tensors)
expert (routed FFN)  ~97 % of bytes
--n-cpu-moe 22  ->  blocks 0..21 on CPU, blocks 22..39 in VRAM
                   CPU-resident expert bytes ≈ 6.5 GiB of PAGE CACHE
                   VRAM-resident expert bytes ≈ 5.8 GiB + 0.34 GiB non-expert
```

RAM budget for the 24B:

```
  6.5 GiB   model expert pages (page cache)
+ 1.4 GiB   zram's compressed copy of cold anon
+ ~2.5 GiB  live anon (desktop + llama-server compute + KV cache)
+ ~1.0 GiB  kernel/slab/buffers
  ----------
  ~11.4 GiB of 15.1 GiB   -> fits, but only if nothing else grabs RAM
```

The observed `MemAvailable` on this box during other agents' benchmarks was
**5.4–7.6 GiB**, which is *not* enough for a 6.5 GiB model working set.
**Concurrency, not swap tuning, is the binding constraint.**

### 2d. TLB

`CONFIG_READ_ONLY_THP_FOR_FS is not set` → the mmap'd model file cannot use
huge pages, not even via khugepaged. The model's ~5 MiB random expert reads
are 4 KiB-granular. This is a hardware/kernel constraint; no sysctl fixes it.

---

## 3. Changes recommended

### 3a. APPLY NOW — bound zram's real-RAM usage (needs root)

The kernel docs: *"mem_limit — specifies the maximum amount of memory ZRAM can
use to store the compressed data."* Currently `mem_limit = 0` = unlimited, with
`disksize = 22.7 GiB` and `vm.swappiness = 180`.

```bash
# live, reversible
sudo sh -c 'echo 6G > /sys/block/zram0/mem_limit'
# revert
sudo sh -c 'echo 0 > /sys/block/zram0/mem_limit'
```

Persist with `systemd/zram-memory-limit.service` (shipped in this repo):

```bash
sudo install -m 0644 systemd/zram-memory-limit.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now zram-memory-limit.service
# revert
sudo systemctl disable --now zram-memory-limit.service
sudo rm -f /etc/systemd/system/zram-memory-limit.service && sudo systemctl daemon-reload
```

Why 6 GiB: measured `mem_used_total` is currently **1.41 GB** with 5.83 GB of
anonymous data swapped out. 6 GiB is a 4.2x margin over the observed working
set and still leaves ~9 GiB of RAM for the page cache.

### 3b. APPLY — sysctl drop-in

`systemd/99-llm-edge-memory.conf` (install to `/etc/sysctl.d/`). It **keeps**
the three values that are already correct and adds one conservative change:

| knob | now | proposed | verdict |
|---|---|---|---|
| `vm.swappiness` | 180 | 180 | keep — zram must absorb cold anon so the page cache can hold the model |
| `vm.vfs_cache_pressure` | 50 | 50 | keep — the single knob that keeps model pages alive |
| `vm.page-cluster` | 0 | 0 | keep — no swapin readahead waste on random expert reads |
| `vm.watermark_boost_factor` | 0 | 0 | keep |
| `vm.watermark_scale_factor` | 125 | 125 | keep |
| `vm.min_free_kbytes` | 67584 | 131072 | optional, **not measured** — more headroom for atomic allocs during model load |

```bash
sudo install -m 0644 systemd/99-llm-edge-memory.conf /etc/sysctl.d/99-llm-edge-memory.conf
sudo sysctl --system
# revert
sudo rm -f /etc/sysctl.d/99-llm-edge-memory.conf && sudo sysctl --system
```

### 3c. DO NOT change

| change | why not |
|---|---|
| `swapoff /swap.img` | zram (prio 100) is always preferred and is never exhausted; `/swap.img` is a pure OOM safety valve. Removing it removes 4 GiB of headroom on a box with 31 OOM kills. It currently holds 0 bytes and does no I/O. |
| raise `vm.page-cluster` | adds swapin readahead; expert reads are random. The upstream llama.cpp 17–35x warning applies to *large* read-ahead; this box is already at the safe values (`page-cluster=0`, `read_ahead_kb=128`). |
| raise `read_ahead_kb` on nvme0n1 | 128 KB is already the default and is correct for random 5 MiB expert reads. |
| `zswap.enabled=1` | zswap in front of zram = double compression for no gain; zswap's own pool is capped at 20 % of RAM and would compete with the model. Currently `zswap.enabled=0` in the cmdline — correct. |
| change the NVMe scheduler | already `none` (the recommended value for random reads). |
| `vm.swappiness = 10` | would let the kernel reclaim the model's page cache instead of swapping cold anon into zram. Strictly worse here. |
| put the model in zram | see 2b — Q4_0 is incompressible; zram would cost 1:1 RAM plus decompression. |
| `vm.dirty_ratio` / `dirty_background_ratio` | irrelevant — the model file is read-only; nothing dirties it. |
| THP `always` | `CONFIG_READ_ONLY_THP_FOR_FS` is off, so the model can never get huge pages. THP only affects the anon KV cache / compute buffers, where the gain is marginal and `always` risks compaction stalls. |

### 3d. Root-free levers that DO matter

| lever | how |
|---|---|
| **Pre-fault the model into the page cache** before starting `llama-server` | `scripts/prefault-model.sh <model.gguf>` — `cat`s the file into the page cache and reports the resident percentage with `mincore(2)`. Removes the NVMe latency from the first tokens. |
| **Serialise `llama-server` runs** | two concurrent servers halve the page cache available for the model. |
| **Pick `--n-cpu-moe` so the CPU-resident expert set fits in RAM** | for the 24B: 22 → ~6.5 GiB CPU experts / ~5.8 GiB VRAM; 24 → ~7.1 GiB CPU / ~5.3 GiB VRAM; 26 → ~7.7 GiB CPU / ~4.7 GiB VRAM. Anything above ~26 will not fit in a 15 GiB box alongside the desktop. |
| `--mlock` | **not usable**: `RLIMIT_MEMLOCK` on this box is 2 030 821 376 B (1.89 GiB) and cannot be raised without root; the CPU-resident expert set is 6.5 GiB, so `mlock` fails and only adds load-time cost. |

---

## 4. Files

| file | purpose |
|---|---|
| `systemd/99-llm-edge-memory.conf` | sysctl drop-in to install at `/etc/sysctl.d/` |
| `systemd/zram-memory-limit.service` | systemd oneshot that sets `/sys/block/zram0/mem_limit = 6G` |
| `scripts/prefault-model.sh` | pre-faults a GGUF into the page cache, reports residency |
| `scripts/mmap_resident.py` | `mincore(2)`-based page-cache residency probe (no root needed) |
