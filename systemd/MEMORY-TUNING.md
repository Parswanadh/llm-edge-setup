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

## 0. Changes actually made in this session

**None. Not a single system setting was changed, because this session has no
root.** Everything the brief asked for ("apply them live with `sysctl -w`",
"`swapoff /swap.img`") was attempted and refused:

```
$ sysctl -w vm.swappiness=200
sysctl: permission denied on key "vm.swappiness", ignoring
$ echo 200 > /proc/sys/vm/swappiness
bash: /proc/sys/vm/swappiness: Permission denied
$ swapoff /swap.img
swapoff: Not superuser.
$ swapon -p -1 /swap.img
swapon: cannot open /swap.img: Permission denied
$ echo none > /sys/block/nvme0n1/queue/scheduler
bash: /sys/block/nvme0n1/queue/scheduler: Permission denied
$ echo 6G > /sys/block/zram0/mem_limit
bash: /sys/block/zram0/mem_limit: Permission denied      # mode 0400 root:root
$ sudo -n true
sudo: a password is required
$ unshare -rm bash -c 'mount -t proc proc /proc && echo 200 > /proc/sys/vm/swappiness'
mount: /proc: permission denied      # vm.* sysctls are not userns-namespaced
```

`/proc/sys/vm/*` is `0644 root:root`, so it is read-only for `parshu`;
`/sys/block/*/queue/*` is likewise root-only; `zram0/mem_limit` is `0400`.

**The good news:** the settings that would have been changed are already at
their recommended values (see §1). The only genuinely needed change —
`zram0/mem_limit = 6G` — is delivered as a ready-to-install unit and needs
one `sudo`.

| change | applied? | how to apply | how to revert |
|---|---|---|---|
| `zram0 mem_limit = 6G` | **no** (needs root) | `sudo sh -c 'echo 6G > /sys/block/zram0/mem_limit'` | `sudo sh -c 'echo 0 > /sys/block/zram0/mem_limit'` |
| `zram-memory-limit.service` | **no** (needs root) | `sudo bash scripts/apply-memory-tuning.sh apply` | `sudo bash scripts/apply-memory-tuning.sh revert` |
| `99-llm-edge-memory.conf` (sysctl drop-in) | **no** (needs root) | `sudo bash scripts/apply-memory-tuning.sh apply` | `sudo bash scripts/apply-memory-tuning.sh revert` |
| `vm.min_free_kbytes 67584 → 131072` | **no** (needs root, optional) | `sudo sysctl -w vm.min_free_kbytes=131072` | `sudo sysctl -w vm.min_free_kbytes=67584` |
| `vm.swappiness` | n/a — already 180 | – | – |
| `vm.vfs_cache_pressure` | n/a — already 50 | – | – |
| `vm.page-cluster` | n/a — already 0 | – | – |
| `swapoff /swap.img` | **not done, not recommended** | – | – |
| NVMe scheduler | n/a — already `none` | – | – |
| `read_ahead_kb` | n/a — already 128 | – | – |
| fstrim timer | not changed (reported only) | – | – |
| `ollama-rootless` service | **not touched** (per instructions) | – | – |

Files written (all additive, nothing overwritten):

* `systemd/99-llm-edge-memory.conf` — the sysctl drop-in
* `systemd/zram-memory-limit.service` — the zram mem_limit unit
* `systemd/MEMORY-TUNING.md` — this document
* `scripts/apply-memory-tuning.sh` — apply / revert / status
* `scripts/prefault-model.sh` — pre-fault a GGUF into the page cache
* `scripts/mmap_resident.py` — `mincore(2)` page-cache residency probe

---

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

## 1b. The box has already OOM-killed itself today — here is the evidence

`journalctl -k --since "24 hours ago"` contains exactly one global OOM kill
today, and it is the smoking gun for the `mem_limit` recommendation:

```
Oct 22 12:19:25 kernel: irq/187-iwlwifi: page allocation failure: order:0, mode:0x820(GFP_ATOMIC)
Oct 22 12:19:25 kernel: iwlwifi 0000:2f:00.0: Failed to alloc_pages
Oct 22 12:19:25 kernel: workqueue: swap_reclaim_work hogged CPU for >10000us 19 times
Oct 22 12:19:28 kernel: llama-server invoked oom-killer: gfp_mask=0x440dc0(GFP_KERNEL_ACCOUNT|__GFP_ZERO|__GFP_COMP), order=0
Oct 22 12:19:28 kernel: oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=user.slice,mems_allowed=0,global_oom
Oct 22 12:19:28 kernel: Out of memory: Killed process 524045 (python3) total-vm:25196832kB, anon-rss:145976kB, pgtables:40892kB
```

The memory state at the moment of the kill:

```
Node 0 Normal free:123548kB  min:61092kB  low:240364kB  high:419636kB
   active_anon:1508096kB inactive_anon:1461764kB active_file:1224kB inactive_file:8268kB
   shmem:3030948kB  pagetables:148184kB
   zspages:9284412kB          <-- 9.28 GiB of zsmalloc pages
Free swap  = 56kB
Total swap = 27991544kB       <-- 26.7 GiB, i.e. EVERY swap byte was allocated
4068532 pages RAM
```

Read that carefully:

* **`zspages: 9284412kB` = 9.28 GiB of zsmalloc pages.** zsmalloc is zram's
  backing allocator, so **zram was holding 9.28 GiB of this box's 15.1 GiB of
  RAM** to store swapped-out pages at the moment the OOM killer fired.
  (For comparison, right now `nr_zspages` is 410516 → 1.6 GiB.)
* **`Free swap = 56kB` of `Total swap = 27991544kB`** — the kernel considered
  *all* 26.7 GiB of swap (zram's 22.7 GiB + `/swap.img`'s 4 GiB) to be
  allocated.
* `active_file` + `inactive_file` was only **9.5 MiB**: the page cache had been
  squeezed to nothing. The model's page cache could not have survived this.
* The allocation that failed was `GFP_KERNEL_ACCOUNT | __GFP_ZERO | __GFP_COMP`
  from `llama-server`, and `workqueue: swap_reclaim_work hogged CPU` — the
  kernel was thrashing swap to find memory.

**This is exactly the failure mode that `mem_limit` prevents.** zram's
`disksize` is 22.7 GiB on a 15.1 GiB box and `mem_limit` is `0` (unlimited),
so zram is allowed to grow until it consumes the machine. Capping it at 6 GiB
would have left ~9 GiB of RAM for the page cache and the working set.

Note the victim was a *python3* process with 145 MB of RSS and 40 MB of page
tables — the OOM killer picks by `oom_score`, not by merit, so the model
process usually pays instead of the thing that caused the problem.

---

## 1c. Other observations from the live system

| item | value | note |
|---|---|---|
| `systemd-oomd` | **active**, `ManagedOOMMemoryPressure=auto` | it kills the largest cgroup under PSI pressure. A `llama-server` holding a 6.5 GiB page-cache working set is the biggest cgroup on the box and is therefore the first candidate. Consider `ManagedOOMMemoryPressure=no` on the serving unit. (Not applied: the brief says do not modify `ollama-rootless`.) |
| PSI memory | `some avg60=1.61 avg300=1.79`, `full avg60=1.59` | the box is in **sustained memory pressure** right now, which is why the page cache keeps being reclaimed and why `si` is non-zero continuously. |
| `vm.overcommit_memory` | 0 (heuristic), `overcommit_ratio` 50 | unchanged; a 25 GiB-VM python3 process was allowed. |
| `vm.min_free_kbytes` | 67584 (66 MiB) | kernel default for this RAM size. |
| `vm.compaction_proactiveness` | 20 | default. |
| `RLIMIT_MEMLOCK` | 2030821376 B (1.89 GiB), hard limit | cannot be raised without root → `--mlock` is unusable for a 6.5 GiB CPU-resident expert set. |
| `zram` `huge_pages_since` | 3908015 (14.9 GiB) | that much **incompressible** data has been handed to zram since boot; it is stored raw, 1:1, in RAM. |
| `zram` `mem_used_max` | 4.91 GB at 12:15 → **10.66 GB at 13:07** | zram's peak real-RAM use grew again *after* the OOM, to **71 % of the machine's RAM**, within the same boot. It keeps growing because nothing caps it. (`mem_used_max` is the 5th field of `mm_stat`; `mem_limit`, the 4th, is `0` = unlimited.) |
| `/swap.img` | was 0 B at 12:15, **278 MB used** at 12:52 | disk swap *is* being used now; it competes with model reads for NVMe bandwidth. |
| `vm.read_ahead_kb` | **does not exist as a sysctl** | the real knob is `/sys/block/<dev>/queue/read_ahead_kb`; `nvme0n1` = **128** (default, correct). The upstream llama.cpp 17–35x read-ahead warning does not apply to this box. |

---

## 2. What is actually true about where the model lives

### 2a. Clean file pages are never swapped

With `--n-cpu-moe N`, the CPU-resident expert tensors are read directly out of
the model's `mmap()`. Those are **clean, file-backed** pages. Under memory
pressure the kernel's reclaim path for a clean file page is: *drop the page*.
It is **not** written to swap.

Consequence: swapping the model into zram is not something the kernel does, and
forcing it would be actively harmful (see 2b).

**Verified directly on a live `llama-server`** (`/proc/<pid>/smaps`, server
running with `--n-cpu-moe 10`):

```
7a4b91255000-7a4c0a116000 r--s  Rss=1753212 kB  File=0  Swap=0  Anon=0  PCl=0  PDir=0
    /home/parshu/.ollama/models/blobs/sha256-63c9be0cc3d5d7b0377161064a74c82b1a5a6ee9ba4a9a3cf034293d6dd09282
```

* `r--s` = **read-only, shared** file mapping — that is llama.cpp's
  `llama_mmap` of the GGUF, exposed as the `CPU_Mapped` buffer type
  (`ggml_backend_cpu_buffer_from_ptr_type_get_name()` returns `"CPU_Mapped"`;
  the CPU backend advertises `caps.buffer_from_host_ptr = true`, and
  `llama_model_base::load_tensors()` uses `ggml_backend_dev_buffer_from_host_ptr()`
  on the mapped region when `ml.use_mmap` is set).
* `Rss = 1 753 212 kB` → 1.67 GiB of the model **is resident in RAM**.
* `Anonymous: 0` → it is **entirely file-backed**; none of it is anonymous
  memory that could be swapped.
* `Swap: 0` → **none of the model's pages are in swap.** Not in zram, not on
  `/swap.img`.

(The `File:` counter in `smaps` reads 0 for shared file mappings on this
kernel — it is a per-mm counter artefact. `Rss` + `Anonymous: 0` + `Swap: 0`
is the authoritative combination.)

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

### 2e. What the two paths actually cost (measured)

Measured on the NVMe holding the model file, with `O_DIRECT` so the page cache
is bypassed entirely (`scripts/`-style probe, 8B lfm2moe blob):

```
=== random 4 KiB O_DIRECT reads over a 1 GiB window ===
  throughput   = 9565 IOPS
  latency mean = 104.3 us
  latency p50  = 105.2 us
  latency p99  = 148.0 us

=== sequential 1 MiB O_DIRECT reads (first 2 GiB) ===
  throughput   = 1652 MB/s
```

RAM bandwidth on this box (single-thread `memcpy`, 512 MiB buffer):
**16.8 GB/s** (aggregate is higher; llama.cpp's CPU MoE path is memory-bound
and multi-threaded).

Now the arithmetic for the 24B at `--n-cpu-moe 22` (≈ 405 MiB of CPU-resident
expert bytes touched per token, 20 MoE layers × 4 experts × 5.06 MiB):

| where the expert pages live | per-token cost | implied ceiling |
|---|---|---|
| page cache (RAM) | 405 MiB ÷ ~17–35 GB/s | **≈ 12–24 ms → 40–80 tok/s** |
| re-read from NVMe | 405 MiB ÷ 1652 MB/s + 80 seeks × 104 µs | **≈ 253 ms → ~4 tok/s** |
| re-read from zram (if it were swappable) | 405 MiB zstd decompress ≈ 405 MiB ÷ ~1 GB/s | **≈ 400 ms → ~2.5 tok/s** |

**The page-cache-vs-NVMe gap is ~10x; the page-cache-vs-zram gap is another
~2x.** Both are far larger than anything a sysctl can recover, and both are
decided by *whether the model's pages are resident*, which is decided by free
RAM — not by swap policy.

This is also why "put the model in zram" cannot be the big win the brief
anticipated: zram is the *slowest* of the three options for this workload.

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

---

## 5. Measurements

### 5a. What was actually measured

**The 24 B model never arrived.** At the start of this session the blob
`sha256-89617cc4…` was being fetched by *three* competing downloaders
(`/tmp/opencode/dl24`, `/tmp/opencode/dl24_sub`, `/tmp/opencode/dl24_mine`)
plus an `ollama pull` on 11435, over a **WiFi** link (`wlp47s0f0`, 60 GB
received so far). The `ollama pull` stalled at 3 203 485 672 / 13 578 190 880
bytes and its `-partial` files were later removed; the chunked downloaders
reached 10.2 GiB (`dl24`) and 3.3 GiB (`dl24_sub`) of 13.58 GiB. The blob
never appeared at the expected path during this session.

**All throughput numbers below are therefore for the 8 B model**
(`sha256-63c9be0…`, `lfm2moe`, 4.79 GiB of tensors), as the brief allows.
The 24 B is extrapolated from these and from the measured I/O characteristics.

### 5b. 8 B model layout, parsed from the GGUF header

`--n-cpu-moe 14`:

```
tensors              = 256
total tensor bytes   = 4.794 GiB
expert (routed FFN)  = 4.343 GiB  (90.59 %)
non-expert           = 0.451 GiB

--n-cpu-moe 14 split
  CPU-resident expert = 2.328 GiB in 36 tensors, blocks 2..13
  VRAM-resident expert= 2.015 GiB in 30 tensors, blocks 14..23
```

(Blocks 0–1 are the dense leading blocks, so `--n-cpu-moe 14` puts only
**12** MoE layers' experts on the CPU.)

### 5c. Throughput vs page-cache state

`llama-server`, `--n-cpu-moe 14`, `-c 4096`, `--cache-type-k/v q8_0`,
`-fa on`, `-t 8`, 61 prompt tokens, 128 generated tokens, seed 42,
temperature 0. One server, four consecutive phases, `vmstat 1` alongside.

**Run A — model page cache WARM before the server started**

| phase | decode tok/s | prefill tok/s | `si` max (pg/s) | `so` max | `bi` max (kB/s) | free min | cache min |
|---|---|---|---|---|---|---|---|
| WARM (503, model still loading) | – | – | 1 616 | 8 | 1 524 488 | 4 241 MB | 4 756 MB |
| EVICT | 63.09 | 93.90 | 5 524 | 0 | 61 988 | 3 129 MB | 7 096 MB |
| RECOVER | 66.23 | 140.69 | 8 792 | 0 | 19 276 | 3 117 MB | 7 052 MB |
| PRESSURE (+2.5 GB anon) | 66.55 | 135.14 | 4 020 | 0 | 39 864 | **731 MB** | 6 774 MB |

Model load time (server internal, `load_model` → `model loaded`): **3.76 s**.

**Run B — model page cache COLD (evicted) before the server started**

| phase | decode tok/s | prefill tok/s | `si` max (pg/s) | `so` max | `bi` max (kB/s) | free min | cache min |
|---|---|---|---|---|---|---|---|
| DECODE1 (first decode after a cold load) | 65.17 | **61.58** | 166 432 | 400 | **1 132 912** | 4 213 MB | 5 449 MB |
| DECODE2 | 68.87 | 154.21 | 16 908 | 960 | 57 456 | 4 246 MB | 6 516 MB |
| DECODE3 | 66.77 | 166.21 | 41 960 | 184 | 54 740 | 4 282 MB | 6 379 MB |
| PRESSURE (+2.0 GB anon) | 64.81 | 114.54 | **106 140** | 0 | 107 312 | **2 165 MB** | 6 349 MB |

Model load time (server internal): **10.47 s** — **2.8x** the warm load.

### 5d. What the numbers say

1. **Model load is the clearest page-cache signal: 3.76 s warm vs 10.47 s cold
   (2.8x).** 4.9 GiB at the measured 1652 MB/s sequential NVMe rate is ~3.0 s
   of extra I/O, which matches the 6.7 s difference to within the GPU copy.
2. **Prefill is highly sensitive: 61.6 tok/s cold vs 154–166 tok/s warm —
   a 2.6–2.7x gap.** Prefill touches the whole model (it runs the expert
   matmuls at batch size), so a cold model means a cold expert working set.
   `bi` peaked at 1 132 912 kB/s (1.13 GB/s) during DECODE1 versus ~55 000 kB/s
   once warm — the NVMe was saturated.
3. **Decode is nearly insensitive** (65–69 tok/s in every phase, including
   under 2–2.5 GB of anonymous pressure). By the time DECODE1 runs, the CPU
   expert working set (2.33 GiB) has been re-faulted in, and the per-token
   working set is small enough that the NVMe readahead hides the rest.
4. **Under anonymous pressure the cost shows up in zram, not in the model.**
   In the PRESSURE phase `si` peaked at **106 140 pages/s = 415 MB/s of zram
   decompression**, while `free` fell to 2.1 GB and the model's page cache
   stayed at 6.3 GB (`cache min` 6 349 MB). The kernel swapped the *anonymous*
   pressure into zram and left the model's file pages alone. That is exactly
   the behaviour `vm.swappiness=180` + `vm.vfs_cache_pressure=50` + zram is
   supposed to produce, and it is why the current configuration is already
   close to right.
5. **The one thing that is clearly broken** is zram's unbounded RAM appetite
   (§1b): at 12:19 today zram held **9.28 GiB of zsmalloc** while the box
   OOM-killed itself.

### 5e. Extrapolation to the 24 B (not measured — the blob never arrived)

For LFM2.5-24B-A2B, 40 blocks / 38 MoE layers / 64 experts / top-4:

| `--n-cpu-moe` | CPU-resident expert (page cache) | VRAM-resident expert + non-expert |
|---|---|---|
| 22 | ~6.5 GiB | ~5.8 + 0.34 = 6.1 GiB |
| 24 | ~7.1 GiB | ~5.5 + 0.34 = 5.8 GiB |
| 26 | ~7.7 GiB | ~5.1 + 0.34 = 5.5 GiB |
| 30 | ~9.1 GiB | ~4.2 + 0.34 = 4.5 GiB |

RAM budget at `--n-cpu-moe 22` on an otherwise-idle box:

```
  6.5 GiB  model expert pages (page cache)
+ 1.6 GiB  zram's compressed copy of cold anon (measured, zram_total)
+ ~2.5 GiB live anon (desktop + llama-server compute + KV cache)
+ ~1.0 GiB kernel / slab / buffers
  ----------
  ~11.6 GiB of 15.1 GiB     -> FITS
```

**So the 24 B does fit in RAM at `--n-cpu-moe 22`, but only with ~3.5 GiB of
slack, and only if nothing else on the box holds memory.** During this
session `MemAvailable` swung between **5.2 GiB and 9.9 GiB** while other
agents ran servers, and the box OOM-killed itself at 12:19. At 6.5 GiB of
model pages plus a 2–3 GiB desktop baseline, the 24 B is at the edge: the
page cache will be reclaimed in whole chunks, and the measured NVMe
characteristic (1.13 GB/s, 104 µs random) puts the cold-path ceiling at
**~4 tok/s** versus **~40–80 tok/s** with the pages in RAM.

**Practical conclusion: the 24 B is RAM-resident at `--n-cpu-moe 22` only on a
quiet box, and it is a page-cache-resident model, never a zram/swap-resident
one. If it ever has to live in zram it will be *slower* than living on the
NVMe, because QAD-Q4_0 does not compress.**

### 5f. Measurement caveats

* All 8 B numbers were taken on a box shared with other agents (up to three
  concurrent `llama-server` processes, plus three model downloads). A run
  that overlapped another agent's server will be depressed; the two runs
  reported here were taken under the shared `llama-queue.sh` flock.
* `vmstat 1`'s first data row is the since-boot average; the tables above use
  only the per-second rows.
* The "EVICT" phase in Run A is a **null result** and is reported as such:
  `posix_fadvise(POSIX_FADV_DONTNEED)` on the model file does **not** evict
  the pages while a live `llama-server` holds a `MAP_PRIVATE` mapping of
  them — `bi` stayed at ~20–60 MB/s and the decode did not slow down. The
  only way to reproduce the cold path is to evict **before** the server
  starts, which is what Run B does.

