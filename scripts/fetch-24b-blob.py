#!/usr/bin/env python3
"""Fetch an Ollama registry blob with a resumable parallel range downloader.

Ollama's own `ollama pull` on this box was repeatedly stalling, restarting and
discarding its `-partial` file (see docs/lfm25-agent-integration.md). This
helper instead:

  1. resolves the registry's 307 redirect to the CDN (Cloudflare R2) signed URL
     once, and reuses it for every range request,
  2. downloads fixed-size chunks with a bounded worker pool, retrying each chunk
     independently,
  3. records completed chunks on disk so the run is resumable after an abort,
  4. verifies the SHA-256 of the assembled file before it is installed.

Usage:
    fetch-24b-blob.py --digest sha256:89617cc4... --out /path/to/blob [--workers 24]
    fetch-24b-blob.py --digest sha256:89617cc4... --install   # place into
                                                          # ~/.ollama/models/blobs
"""
import argparse
import hashlib
import os
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

REGISTRY = "https://registry.ollama.ai/v2/library/lfm2.5/blobs/sha256:{digest}"


def resolve_cdn_url(digest: str) -> str:
    """Return the CDN URL the registry redirects to for this blob."""
    url = REGISTRY.format(digest=digest.split(":", 1)[-1])
    out = subprocess.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{redirect_url}",
         "-r", "0-100", url],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not out:
        raise SystemExit("registry did not return a redirect URL for " + digest)
    return out


def head_size(digest: str) -> int:
    url = REGISTRY.format(digest=digest.split(":", 1)[-1])
    out = subprocess.run(
        ["curl", "-sI", url], capture_output=True, text=True, check=True
    ).stdout
    for line in out.splitlines():
        if line.lower().startswith("content-length:"):
            return int(line.split(":", 1)[1].strip())
    raise SystemExit("could not determine blob size")


def fetch_chunk(cdn_url, path, start, end, tries=8):
    """Download byte range [start, end] into `path`. Returns True on success."""
    want = end - start + 1
    for attempt in range(tries):
        have = os.path.getsize(path) if os.path.exists(path) else 0
        if have == want:
            return True
        if have > want:
            os.remove(path)
            have = 0
        # resume from where this chunk left off
        s = start + have
        rc = subprocess.run(
            ["curl", "-sL", "--max-time", "900", "--speed-limit", "10000",
             "--speed-time", "120",
             "-r", f"{s}-{end}", cdn_url, "-o", path + ".part"],
            capture_output=True,
        ).returncode
        if os.path.exists(path + ".part"):
            got = os.path.getsize(path + ".part")
            with open(path, "ab") as dst, open(path + ".part", "rb") as src:
                dst.write(src.read())
            os.remove(path + ".part")
        if rc == 0 and os.path.exists(path) and os.path.getsize(path) == want:
            return True
        time.sleep(min(2 ** attempt, 20))
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--digest", required=True,
                    help="sha256:<hex> digest of the blob")
    ap.add_argument("--out", required=True, help="output file path")
    ap.add_argument("--workdir", default=None,
                    help="chunk cache dir (default: <out>.parts)")
    ap.add_argument("--chunk-mb", type=int, default=16)
    ap.add_argument("--workers", type=int, default=24)
    ap.add_argument("--install", action="store_true",
                    help="also copy the verified blob into the Ollama model store")
    ap.add_argument("--install-dir", default=None,
                    help="Ollama blob dir (default: $OLLAMA_MODELS/blobs)")
    args = ap.parse_args()

    digest = args.digest.split(":", 1)[-1]
    total = head_size(args.digest)
    print(f"blob size: {total} bytes ({total/2**30:.2f} GiB)")

    workdir = args.workdir or (args.out + ".parts")
    os.makedirs(workdir, exist_ok=True)

    chunk = args.chunk_mb * 1024 * 1024
    ranges = []
    i = 0
    while i * chunk < total:
        s = i * chunk
        e = min(s + chunk - 1, total - 1)
        ranges.append((i, s, e))
        i += 1
    print(f"chunks: {len(ranges)} x {args.chunk_mb} MiB, workers={args.workers}")

    cdn_url = resolve_cdn_url(args.digest)
    print("cdn url resolved")

    lock = threading.Lock()
    state = {"done": 0, "bytes": 0, "fail": 0, "t0": time.time()}

    def work(item):
        idx, s, e = item
        path = os.path.join(workdir, "c%05d" % idx)
        want = e - s + 1
        if os.path.exists(path) and os.path.getsize(path) == want:
            with lock:
                state["done"] += 1
                state["bytes"] += want
            return True
        ok = fetch_chunk(cdn_url, path, s, e)
        with lock:
            state["done"] += 1
            if ok:
                state["bytes"] += want
            else:
                state["fail"] += 1
            n = state["done"]
            if n % 20 == 0 or state["fail"]:
                el = time.time() - state["t0"]
                rate = state["bytes"] / max(el, 1) / 1e6
                eta = (total - state["bytes"]) / max(rate * 1e6, 1)
                print(f"  {n}/{len(ranges)} chunks  {state['bytes']/2**30:.2f} GiB  "
                      f"{rate:.2f} MB/s  ETA {eta/60:.0f} min  fails={state['fail']}",
                      flush=True)
        return ok

    with ThreadPoolExecutor(max_workers=args.workers) as ex:
        results = list(ex.map(work, ranges))

    if not all(results):
        print(f"FAILED: {state['fail']} chunks incomplete; re-run to resume")
        return 1

    print("assembling ...", flush=True)
    with open(args.out + ".tmp", "wb") as dst:
        for idx, _, _ in ranges:
            with open(os.path.join(workdir, "c%05d" % idx), "rb") as src:
                while True:
                    b = src.read(8 << 20)
                    if not b:
                        break
                    dst.write(b)
    got = os.path.getsize(args.out + ".tmp")
    if got != total:
        print(f"SIZE MISMATCH: {got} != {total}")
        return 1
    print("verifying sha256 (13.5 GiB, a few minutes) ...", flush=True)
    h = hashlib.sha256()
    with open(args.out + ".tmp", "rb") as fh:
        while True:
            b = fh.read(16 << 20)
            if not b:
                break
            h.update(b)
    if h.hexdigest() != digest:
        print(f"SHA256 MISMATCH: got {h.hexdigest()}")
        return 1
    os.rename(args.out + ".tmp", args.out)
    print(f"SHA256 OK -> {args.out}")

    if args.install:
        install_dir = args.install_dir or os.path.join(
            os.environ.get("OLLAMA_MODELS", os.path.expanduser("~/.ollama/models")), "blobs")
        os.makedirs(install_dir, exist_ok=True)
        dest = os.path.join(install_dir, "sha256-" + digest)
        if os.path.exists(dest):
            print(f"already installed: {dest}")
        else:
            print(f"installing -> {dest}")
            subprocess.run(["cp", args.out, dest], check=True)
        print("now run: ollama pull lfm2.5:24b-a2b-q4_0   (blob is present; it will only write the manifest)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
