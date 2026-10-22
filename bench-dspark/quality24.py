#!/usr/bin/env python3
"""Quality A/B: same 3 prompts with and without the DSpark drafter on LFM2.5-24B-A2B."""
import json, os, sys, difflib
sys.path.insert(0, "/home/parshu/llm-edge-setup/bench-dspark")
from ab24 import run_case, spec_args, DSF

QUALITY_PROMPTS = [
    ("arith",
     "Solve step by step: A train leaves station A at 9:00 travelling at 60 km/h toward station B, "
     "which is 180 km away. A second train leaves B at 9:30 travelling at 90 km/h toward A. "
     "At what time do they meet, and how far from A is the meeting point? "
     "Explain your reasoning carefully and give the final answer as a number of kilometres from A."),
    ("code",
     "Write a Python function `merge_intervals(intervals)` that takes a list of (start, end) pairs "
     "and returns the merged, non-overlapping intervals. Include a type hint, a docstring, and three "
     "doctest examples. Then explain how you would make it work on a stream of intervals with O(1) "
     "extra memory."),
    ("toolcall",
     "You are a coding agent. Call the function `get_weather` with the arguments "
     "{\"city\": \"Berlin\", \"unit\": \"celsius\"} to find out the current weather, "
     "and explain what you are doing."),
]

NC = ["--n-cpu-moe", os.environ.get("NCPU", "22")]
NMAX = os.environ.get("NMAX", "8")
CTX = int(os.environ.get("CTX", "8192"))
THR = os.environ.get("THR", "16")

out = {}
for tag, extra in (("baseline", NC), ("dspark", spec_args(DSF, "draft-dspark", NMAX) + NC)):
    for pname, p in QUALITY_PROMPTS:
        r = run_case(f"q_{tag}_{pname}", extra, prompt=p, n_predict=160, reps=1,
                     ctx=CTX, threads=THR)
        if r:
            out.setdefault(tag, {})[pname] = r["contents"][0] if r["contents"] else ""

with open("/tmp/opencode/ab24/quality.json", "w") as f:
    json.dump(out, f, indent=1)

print("\n\n================ QUALITY COMPARISON ================")
for pname, _ in QUALITY_PROMPTS:
    a = out.get("baseline", {}).get(pname, "")
    b = out.get("dspark", {}).get(pname, "")
    same = (a == b)
    print(f"\n--- {pname}: identical={same} (len {len(a)} vs {len(b)})")
    if not same:
        i = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        print(f"    first divergence at char {i}")
        print(f"    baseline: ...{a[max(0,i-150):i+200]!r}")
        print(f"    dspark  : ...{b[max(0,i-150):i+200]!r}")
        print(f"    similarity ratio: {difflib.SequenceMatcher(None, a, b).ratio():.4f}")
