#!/usr/bin/env python3
"""
DSpark vs DFlash A/B for LFM2.5-24B-A2B on RTX 4070 Laptop (8 GB).

Runs the bundled llama-server through the shared lock wrapper
(/home/parshu/.local/lib/ollama-new/llama-server.locked). The ollama-rootless
service is never touched.

Usage:
  python3 ab24.py --cases all
  python3 ab24.py --cases baseline,dspark_n8
"""
import argparse, json, os, signal, subprocess, sys, time, threading, urllib.request

LS   = "/home/parshu/.local/lib/ollama-new/llama-server.locked"
LIBD = "/home/parshu/.local/lib/ollama-new"
CUDA = "/home/parshu/.local/lib/ollama-new/cuda_v13"
# target GGUF: prefer the canonical ollama blob, fall back to the parallel downloader output
CANON = "/home/parshu/.ollama/models/blobs/sha256-89617cc4d3a52e973ee8dea72c7df04285f582107385796ba903f81e540e4afa"
ALT   = "/tmp/opencode/lfm25-24b-q4_0.gguf"
DSF   = "/home/parshu/llm-edge-setup/models/LFM2.5-24B-A2B-DSpark-F16.gguf"
DS8   = "/home/parshu/llm-edge-setup/models/LFM2.5-24B-A2B-DSpark-Q8_0.gguf"
DS4   = "/home/parshu/llm-edge-setup/models/LFM2.5-24B-A2B-DSpark-Q4_K_M.gguf"
LOG   = "/tmp/opencode/ab24"
PORT  = 19981
QUEUESH = "/home/parshu/llm-edge-setup/scripts/llama-queue.sh"

os.makedirs(LOG, exist_ok=True)
ENV = dict(os.environ)
ENV["LD_LIBRARY_PATH"] = f"{LIBD}:{CUDA}"
ENV["GGML_BACKEND_PATH"] = f"{CUDA}/libggml-cuda.so"

PERF_PROMPT = (
    "You are a senior software engineer explaining a production incident. "
    "A service that normally serves 4200 requests per second suddenly drops to 380 requests per second "
    "for eleven minutes and then recovers on its own without any deploy or configuration change. "
    "The service is a Go API server behind an nginx ingress, talking to a Postgres primary in a "
    "different availability zone. The only related change in the previous week was that a background "
    "analytics job that scans the orders table every six hours was moved from a cron pod to a "
    "Kubernetes CronJob with a slightly different query plan. Explain, step by step, your ranked "
    "hypothesis list for the root cause, the specific metrics, logs and traces you would inspect to "
    "confirm or eliminate each hypothesis in order, and the exact mitigation you would apply first "
    "plus the permanent fix you would propose to engineering. Be concrete, cite specific PostgreSQL, "
    "nginx, connection pool and kernel level knobs where relevant, and explain the reasoning behind "
    "each step rather than just listing tools. End with a short ordered runbook of the first five "
    "commands an on-call engineer should run in the first ten minutes."
)


def target_path():
    env = os.environ.get("TARGET_GGUF")
    if env:
        return env if os.path.exists(env) else None
    for p in (CANON, ALT):
        if os.path.exists(p) and os.path.getsize(p) == 13578190880:
            return p
    return None


def sh(c):
    return subprocess.run(c, shell=True, capture_output=True, text=True).stdout.strip()


def meminfo():
    d = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":")
        d[k] = int(v.strip().split()[0]) * 1024
    return d


def vmstat_swaps():
    d = {}
    for line in open("/proc/vmstat"):
        k, v = line.split()
        d[k] = int(v)
    return d["pswpin"], d["pswpout"]


def gpu_used():
    try:
        out = sh("nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits")
        return int(out.strip().splitlines()[0])
    except Exception:
        return -1


def wait_vram_free(limit=700, timeout=300):
    t0 = time.time()
    while time.time() - t0 < timeout:
        u = gpu_used()
        if u <= limit:
            return u
        time.sleep(3)
    return gpu_used()


class VramWatch(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.peak = 0
        self.stop = False

    def run(self):
        while not self.stop:
            u = gpu_used()
            if u > self.peak:
                self.peak = u
            time.sleep(0.4)


def post(port, payload, timeout=900):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/completion",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def wait_health(port, pid, timeout_s=420):
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3).read()
            return True
        except Exception:
            pass
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        time.sleep(1)
    return False


def run_case(name, extra, prompt=PERF_PROMPT, n_predict=128, ctx=8192,
             reps=3, port=PORT, threads="16", model=None):
    model = model or target_path()
    if not model:
        print(f"!! SKIP {name}: target GGUF not available", flush=True)
        return None
    mi = meminfo()
    avail = mi["MemAvailable"]
    if avail < 2 * 1024 ** 3:
        print(f"!! SKIP {name}: only {avail/1e9:.2f} GB MemAvailable", flush=True)
        return None
    print(f"[queue] {sh(f'bash {QUEUESH} status')}", flush=True)
    wait_vram_free()
    base = [LS, "-m", model, "--host", "127.0.0.1", "--port", str(port),
            "-c", str(ctx), "-np", "1", "-fa", "on", "--jinja", "-t", threads,
            "-ngl", "99", "--no-warmup", "--log-verbosity", "3"]
    args = base + extra
    logf = f"{LOG}/{name}.server.log"
    print(f"\n===== CASE {name} =====\nARGS: {' '.join(args)}", flush=True)
    with open(logf, "w") as lf:
        p = subprocess.Popen(["timeout", "1500"] + args, env=ENV, stdout=lf,
                             stderr=subprocess.STDOUT, preexec_fn=os.setsid)
    w = VramWatch(); w.start()
    ok = wait_health(port, p.pid)
    if not ok:
        print(f"!! {name}: SERVER DID NOT START", flush=True)
        print(sh(f"grep -iE 'error|assert|abort|out of memory|failed|refusing|gave up' {logf} | tail -14"), flush=True)
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception:
            pass
        w.stop = True
        return None
    time.sleep(3)
    si0, so0 = vmstat_swaps()
    results = []
    for r in range(reps):
        try:
            d = post(port, {"prompt": prompt, "n_predict": n_predict, "temperature": 0.0,
                            "top_k": 1, "seed": 42, "cache_prompt": False, "stream": False})
            t = d.get("timings", {})
            results.append(d)
            print(f"  [{name} r{r}] tok/s={t.get('predicted_per_second'):8.2f} n={t.get('predicted_n')} "
                  f"draft_n={t.get('draft_n')} acc={t.get('draft_n_accepted')} "
                  f"pp_tok/s={t.get('prompt_per_second'):.1f}", flush=True)
        except Exception as e:
            print(f"  [{name} r{r}] REQUEST ERROR: {e}", flush=True)
    si1, so1 = vmstat_swaps()
    ps = 4096
    print(f"  [{name}] swap during requests: si={(si1-si0)*ps//(1024*1024)} MiB "
          f"so={(so1-so0)*ps//(1024*1024)} MiB", flush=True)
    time.sleep(0.5); w.stop = True
    try:
        os.killpg(os.getpgid(p.pid), signal.SIGKILL)
    except Exception:
        pass
    p.wait()
    time.sleep(3)
    mi2 = meminfo()
    sw = (mi2["SwapTotal"] - mi2["SwapFree"]) // (1024 * 1024)
    print(f"  [{name}] peakVRAM={w.peak}MiB | MemAvail {avail/1e9:.2f}->{mi2['MemAvailable']/1e9:.2f}GB "
          f"| swap used {sw}MiB", flush=True)
    with open(f"{LOG}/{name}.results.json", "w") as f:
        json.dump([{k: r.get(k) for k in ("content", "timings")} for r in results], f, indent=1)
    return {"name": name, "args": extra, "peak_vram_mib": w.peak,
            "swap_in_mib": (si1 - si0) * ps // (1024 * 1024),
            "swap_out_mib": (so1 - so0) * ps // (1024 * 1024),
            "timings": [r.get("timings") for r in results],
            "contents": [r.get("content") for r in results]}


def spec_args(draft, stype, nmax, nmin="0", extra=None):
    a = ["-md", draft, "--spec-type", stype, "--spec-draft-n-max", str(nmax),
         "--spec-draft-n-min", nmin, "-ngld", "99"]
    return a + (extra or [])


def build_cases(ncpu, nmaxes):
    NC = ["--n-cpu-moe", str(ncpu)]
    cases = [("baseline", NC)]
    for n in nmaxes:
        cases.append((f"dspark_n{n}", spec_args(DSF, "draft-dspark", n) + NC))
    cases.append(("dflash_mode_n8", spec_args(DSF, "draft-dflash", 8) + NC))
    cases.append(("dspark_q8_n8", spec_args(DS8, "draft-dspark", 8) + NC))
    cases.append(("dspark_q4_n8", spec_args(DS4, "draft-dspark", 8) + NC))
    cases.append(("baseline_moecache1024", NC + ["--moe-cache-mib", "1024"]))
    cases.append(("dspark_n8_moecache1024", spec_args(DSF, "draft-dspark", 8) + NC + ["--moe-cache-mib", "1024"]))
    cases.append(("dspark_n8_pmin", spec_args(DSF, "draft-dspark", 8, nmin="0",
                                              extra=["--spec-draft-p-min", "0.1"]) + NC))
    return cases


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default="all")
    ap.add_argument("--ctx", type=int, default=8192)
    ap.add_argument("--ncpu", type=int, default=22)
    ap.add_argument("--threads", default="16")
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--nmaxes", default="8,6,4")
    args = ap.parse_args()
    cases = build_cases(args.ncpu, [int(x) for x in args.nmaxes.split(",")])
    sel = None if args.cases == "all" else args.cases.split(",")
    out = []
    for name, extra in cases:
        if sel and name not in sel:
            continue
        r = run_case(name, extra, ctx=args.ctx, reps=args.reps, threads=args.threads)
        if r:
            out.append(r)
        with open(f"{LOG}/summary.json", "w") as f:
            json.dump(out, f, indent=1)
    print("\n===== SUMMARY =====")
    for r in out:
        ts = [t.get("predicted_per_second") for t in r["timings"] if t]
        dn = [t.get("draft_n") for t in r["timings"] if t]
        ac = [t.get("draft_n_accepted") for t in r["timings"] if t]
        print(f"{r['name']:<24} tok/s={['%.2f'%x for x in ts]} draft_n={dn} acc={ac} "
              f"peakVRAM={r['peak_vram_mib']}MiB swap_si={r['swap_in_mib']} so={r['swap_out_mib']}")


if __name__ == "__main__":
    main()
