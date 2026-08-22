#!/usr/bin/env python3
"""T4 acceptance checks for the converted trajectory parquet."""

import sys

import pandas as pd

path = sys.argv[1]
df = pd.read_parquet(path)
print(f"rows={len(df)} cols={sorted(df.columns)}")

errors = []

# 1. mask consistency
for i, r in df.iterrows():
    if len(r["response_mask"]) != len(r["response_ids"]):
        errors.append(f"row{i}: mask len {len(r['response_mask'])} != resp len {len(r['response_ids'])}")
    elif sum(r["response_mask"]) != len(r["response_ids"]):
        errors.append(f"row{i}: mask not all-1")

# 2. token id range (DeepSeek V4 vocab ~129k conservative bound; allow special)
vocab_bound = 200000
bad_ids = 0
for col in ["prompt_ids", "response_ids"]:
    for i, r in df.iterrows():
        if any(t < 0 or t >= vocab_bound for t in r[col]):
            bad_ids += 1
            errors.append(f"row{i} {col}: id out of range")
            break

# 3. logprob coverage & sanity
n_lp = 0
lp_bad = 0
lp_vals = []
for i, r in df.iterrows():
    lps = list(r["rollout_logprobs"]) if r["rollout_logprobs"] is not None else []
    if lps:
        n_lp += 1
        if len(lps) != len(r["response_ids"]):
            lp_bad += 1
            errors.append(f"row{i}: logprob len {len(lps)} != resp len {len(r['response_ids'])}")
        else:
            clean = [v for v in lps if v is not None]
            lp_vals.extend(clean)
            if any(v is None for v in lps):
                pass  # partial coverage tolerated, counted below
if lp_vals:
    import math

    mn, mx = min(lp_vals), max(lp_vals)
    mean = sum(lp_vals) / len(lp_vals)
    n_none = 0
    for _, r in df.iterrows():
        n_none += sum(1 for v in (list(r["rollout_logprobs"]) if r["rollout_logprobs"] is not None else []) if v is None)
    print(f"logprobs: turns={n_lp}/{len(df)} positions={len(lp_vals)} mean={mean:.4f} min={mn:.2f} max={mx:.2f} none={n_none}")
    if any(math.isnan(v) for v in lp_vals):
        errors.append("NaN in logprobs")
    if mx > 0.5:
        errors.append(f"suspicious positive logprob max={mx}")

# 4. reward consistency within session
for (sess,), g in df.groupby([df["extra_info"].apply(lambda x: x["session_id"])]):
    if g["reward"].nunique() > 1:
        errors.append(f"session {sess}: inconsistent rewards")

# 5. group stats
print("\nturns per session:")
for (sess,), g in df.groupby([df["extra_info"].apply(lambda x: x["session_id"])]):
    info = g["extra_info"].iloc[0]
    print(f"  {sess:36s} task={info['task_id']:20s} turns={len(g):3d} reward={g['reward'].iloc[0]} verdict={info['verdict']}")

# 6. length stats
pl = df["prompt_ids"].apply(len)
rl = df["response_ids"].apply(len)
print(f"\nprompt len: mean={pl.mean():.0f} p50={pl.median():.0f} max={pl.max()}")
print(f"resp len:   mean={rl.mean():.0f} p50={rl.median():.0f} max={rl.max()}")

print("\n" + ("FAIL:\n" + "\n".join(errors[:20]) if errors else "ALL CHECKS PASSED"))
sys.exit(1 if errors else 0)
