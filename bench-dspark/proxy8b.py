#!/usr/bin/env python3
"""8B-A1B proxy: baseline vs DSpark vs DFlash-mode, same harness as the 24B run."""
import json, os, sys
sys.path.insert(0, "/home/parshu/llm-edge-setup/bench-dspark")
import ab24
from ab24 import run_case, spec_args

T8 = "/home/parshu/.ollama/models/blobs/sha256-63c9be0cc3d5d7b0377161064a74c82b1a5a6ee9ba4a9a3cf034293d6dd09282"
D8 = "/home/parshu/.ollama/models/draft/LFM2.5-8B-A1B-DSpark-Q4_K_M.gguf"
ab24.LOG = "/tmp/opencode/ab24_8b"
os.makedirs(ab24.LOG, exist_ok=True)
os.environ["TARGET_GGUF"] = T8

NC = ["--n-cpu-moe", "10"]
cases = [
    ("p8_base", NC),
    ("p8_dspark_n8", spec_args(D8, "draft-dspark", 8) + NC),
    ("p8_dspark_n4", spec_args(D8, "draft-dspark", 4) + NC),
    ("p8_dflash_n8", spec_args(D8, "draft-dflash", 8) + NC),
]
out = []
for name, extra in cases:
    r = run_case(name, extra, ctx=4096, reps=3, threads="14", model=T8)
    if r:
        out.append(r)
    with open(f"{ab24.LOG}/summary.json", "w") as f:
        json.dump(out, f, indent=1)
print("\n===== 8B PROXY SUMMARY =====")
for r in out:
    ts = [t.get("predicted_per_second") for t in r["timings"] if t]
    dn = [t.get("draft_n") for t in r["timings"] if t]
    ac = [t.get("draft_n_accepted") for t in r["timings"] if t]
    print(f"{r['name']:<18} tok/s={['%.2f'%x for x in ts]} draft_n={dn} acc={ac} peakVRAM={r['peak_vram_mib']}MiB")
