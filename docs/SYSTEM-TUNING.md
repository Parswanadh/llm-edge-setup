# OS & Hardware Tuning for Max LLM Throughput — LFM2.5-24B-A2B on Alienware m16 R2

Target: Intel Core Ultra 7 155H (6P + 8E + 2LP-E), 15 GiB RAM, RTX 4070 Laptop 8 GB, Ubuntu 24.04, NVMe.

## The big levers (measured or well-established)

### 1. CPU governor — `performance`
```bash
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```
`intel_pstate` is the driver; `performance` pins max freq. Sustained LLM inference on `schedutil` scales down under load and loses throughput. OpenVINO Meteor-Lake benchmarks run on `performance`.

### 2. Turbo Boost — disable for long sessions
Gaming laptops lose 15–25 % after 15–20 min sustained load (i9-14900HX: 5.8 → 3.9 GHz). For short bursts keep it; for sustained inference, cap max freq to base (~3.8 GHz) to avoid thermal/VRM throttling. Use a cooling pad (+2–3 cm airflow delays throttle 10→20+ min).

### 3. SMT — disable (or pin P-cores only)
Inference does not benefit from SMT; it hurts (ggml discussion #572). i7-12700H: P-core-only pinning gave **2.4× (7B) and 3× (65B)**. On the 155H, run `-t 6` and pin with `taskset -c 0-5` or `--cpu-range 0-5 --cpu-strict 1`.

### 4. NUMA — marginal on single-socket
155H is a single NUMA node; NUMA tuning barely helps. `--numa distribute` ignores numactl. Set `kernel.numa_balancing=0`. Pin P-cores instead.

### 5. Transparent Hugepages — `madvise` (default)
THP only backs **anonymous** memory, not file-backed mmap (which is how GGUF weights are mapped). No measured LLM benefit from THP for file-backed weights. `always` risks compaction stalls under memory pressure.

### 6. Swap / zram
- zram (22.7 G, priority 100) is RAM-backed compressed swap — far faster than NVMe.
- Keep disk swapfile (4 G, priority -1) as fallback for OOM safety.
- With zram primary: `vm.swappiness=100` (or 180). Without zram: 10–60.
- Swap size ≥ RAM.

### 7. page-cluster — set to 0
`vm.page-cluster=0` disables swap readahead. The llama.cpp docs show 8192 KB costs **17–35×** on models > RAM. Linux default is 128 KB (already OK on this box). Set to 0 for zram + random-access model streaming.

### 8. I/O scheduler — `none`
On NVMe, BFQ/MQ-Deadline can't saturate the device (BFQ 0.40×, MQ-Deadline 0.72× of peak IOPS). Kyber helps with mixed read/write interference (up to 26% lower read latency). For single LLM streaming workload: `none`.

```bash
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler
```

### 9. Page cache tuning
```bash
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
```
Keeps directory cache longer, flushes dirty pages earlier.

### 10. CPU pinning
```bash
taskset -c 0-5 ./llama-server -m model.gguf -t 6 --cpu-range 0-5 --cpu-strict 1
```

### 11. Thermal management (RTX 4070 Laptop)
- Gaming laptops lose 15–25 % after 15–20 min sustained.
- VRM can be the silent bottleneck (>105 °C before CPU hits 90 °C).
- Cap GPU TGP to 115–120 W (preserves >92 % throughput).
- Undervolt if BIOS allows; use cooling pad (+2–3 cm airflow).

### 12. PCIe ASPM — disable
```bash
# kernel cmdline
pcie_aspm=off
```
Reduces NVMe latency from ~80 ms to ~300 µs in one report. Disabling improves sustained throughput.

### 13. NVMe power management (APST)
```bash
nvme_core.default_ps_max_latency_us=0
```
Disables autonomous power state transitions; latency drops from ~10 ms to ~300 µs.

### 14. Other kernel tuning
```bash
vm.max_map_count=524288
vm.overcommit_memory=1
vm.overcommit_ratio=80
kernel.numa_balancing=0
fs.aio-max-nr=1048576
```

---

## Consolidated snippet

```bash
# Kernel cmdline (GRUB)
pcie_aspm=off nvme_core.default_ps_max_latency_us=0 transparent_hugepage=madvise

# sysctl
vm.swappiness=100
vm.page-cluster=0
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
vm.max_map_count=524288
vm.overcommit_memory=1
kernel.numa_balancing=0

# CPU governor
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# I/O scheduler
echo none | sudo tee /sys/block/nvme0n1/queue/scheduler

# llama.cpp invocation example
taskset -c 0-5 ./llama-server -m model.gguf -t 6 --cpu-range 0-5 --cpu-strict 1 -fa on ...
```

**Key caveats:** THP doesn't help file-backed mmap weights; page-cluster is global; `--numa distribute` ignores numactl; thermal throttling dominates sustained performance more than any single sysctl. Always measure with `llama-bench` over 10+ min warm runs.

Sources: [OpenVINO Meteor Lake benchmark](https://github.com/Oaklight/openvino-meteor-lake-ai-inference/blob/main/docs/BENCHMARK_RESULTS.md), [ggml #572](https://github.com/ggml-org/llama.cpp/discussions/572), [llama.cpp discussion #30409](https://github.com/ggml-org/llama.cpp/discussions/30409), [ICPE'24 paper](https://doi.org/10.1145/3629526.3645053), [tqdev](https://www.tqdev.com/2025-check-your-nmve-drive-i-o-latency-disable-apst), [OrientDeck](https://www.orientdeck.com/in-depth-reviews/laptoppc/7107.html), [youngju.dev](https://www.youngju.dev/blog/linux/2026-06-12-linux-memory-hierarchy-swap-zram-hacks.en), [Kernel THP docs](https://www.kernel.org/doc/html/v6.11/admin-guide/mm/transhuge.html), [gigagpu](https://gigagpu.com/swap-space-configuration-ai-inference/)
