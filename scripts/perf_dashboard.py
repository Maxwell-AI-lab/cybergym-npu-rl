#!/usr/bin/env python3
"""Performance dashboard for CyberGym multi-turn RL training.

Aggregates five signal sources into one view (run on the relay):
  1. Training log   — step timing / reward metrics / seqlen / entropy
  2. Trajectory dir — dumped trajectories: score & length distribution
  3. x86 server.out — submission rate / exit-code mix / judge latency
  4. poc.db         — per-task crash leaderboard
  5. Cluster        — training process alive, NPU memory (head sample)

Usage:  python3 perf_dashboard.py [--log /tmp/mt_minimal.log]
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

HEAD = "root@192.168.0.36"
X86 = "root@192.168.0.100"
CONTAINER = "cybergym-baseline-zhouzhi"
TRAJ_DIR = "/data/z00666713/deepseek0715/trajectories"


def ssh(host, cmd, timeout=30):
    try:
        r = subprocess.run(["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=10",
                            host, cmd], capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def sect(title):
    print(f"\n{'='*62}\n {title}\n{'='*62}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", default="/tmp/mt_minimal.log")
    args = ap.parse_args()

    log = ssh(HEAD, f"docker exec {CONTAINER} cat {args.log} 2>/dev/null")

    # ---- 1. training progress ----
    sect("1. TRAINING PROGRESS")
    alive = ssh(HEAD, f"docker exec {CONTAINER} ps aux | grep verl.trainer.main_ppo | grep -v grep | wc -l").strip()
    print(f"process alive: {'YES' if alive not in ('0','') else 'NO'}")
    for m in re.findall(r"(\d+)/(\d+) \[(\d+):(\d+)<", log):
        print(f"progress: step {m[0]}/{m[1]}  elapsed {m[2]}:{m[3]}")
    rd = log.count("REWARD-DBG")
    print(f"reward computations so far: {rd}")
    for line in re.findall(r"rewards/\w+:[0-9.-]+", log)[-6:]:
        print(" ", line)
    for line in re.findall(r"actor/entropy:[0-9.-]+", log)[-2:]:
        print(" ", line)
    for line in re.findall(r"global_seqlen/mean:[0-9.]+", log)[-2:]:
        print(" ", line)

    # ---- 2. trajectories ----
    sect("2. TRAJECTORY DUMPS")
    tdir = Path(TRAJ_DIR)
    files = sorted(tdir.glob("*.json")) if tdir.exists() else []
    print(f"dumped trajectories: {len(files)}  ({TRAJ_DIR})")
    if files:
        scores, lens, via, crash_tasks = [], [], Counter(), Counter()
        for fp in files[-500:]:
            try:
                d = json.loads(fp.read_text())
                scores.append(d["score"]); lens.append(d["len_chars"])
                via[d.get("scored_via", "?")] += 1
                if d.get("score", 0) >= 1.0:
                    crash_tasks[d["task_id"]] += 1
            except Exception:
                pass
        if scores:
            scores.sort(); lens.sort()
            n = len(scores)
            print(f"score: min={scores[0]:.2f} p50={scores[n//2]:.2f} max={scores[-1]:.2f} "
                  f"mean={sum(scores)/n:.2f}  zero-rate={scores.count(0.0)/n:.0%}")
            print(f"length(chars): p50={lens[n//2]} max={lens[-1]}")
            print(f"scoring path: {dict(via)}")
            top = crash_tasks.most_common(5)
            if top:
                print("top crashing tasks:", ", ".join(f"{t}×{c}" for t, c in top))

    # ---- 3. x86 judge ----
    sect("3. JUDGE (x86)")
    out = ssh(X86, "grep 'agent=poc_' /data/cybergym/server.out 2>/dev/null", timeout=60)
    done = re.findall(r"submit-vul done.*exit_code=(\d+)", out)
    if done:
        c = Counter(done)
        total = sum(c.values())
        crash = total - c.get("0", 0)
        print(f"vul verdicts: {total}  crash={crash} ({crash/total:.0%})  exit mix: {dict(c)}")
    mins = re.findall(r"^(\d+:\d+):\d+", out, re.M)
    if mins:
        cm = Counter(mins[-10:])
        rate = sum(cm.values()) / max(len(cm), 1)
        print(f"submission rate (last {len(cm)} min): ~{rate:.0f}/min")
    lats = [float(x) for x in re.findall(r"POST /submit-vul -> 200 \(([\d.]+)ms\)", out)]
    if lats:
        lats.sort()
        print(f"judge latency ms: p50={lats[len(lats)//2]:.0f} p99={lats[int(len(lats)*.99)]:.0f} max={lats[-1]:.0f}")
    fix = re.findall(r"submit-fix done.*exit_code=(\d+)", out)
    if fix:
        cf = Counter(fix)
        clean = cf.get("0", 0)
        print(f"fix verdicts: {len(fix)}  clean={clean} ({clean/max(len(fix),1):.0%} precision)")

    # ---- 4. task leaderboard (poc.db) ----
    sect("4. TASK LEADERBOARD (poc.db, training agents only)")
    q = ("python3 - << 'EOF'\n"
         "import sqlite3\n"
         "db = sqlite3.connect('/data/cybergym/poc.db')\n"
         "rows = db.execute(\"SELECT task_id, COUNT(*), SUM(vul_exit_code!=0) FROM poc_records "
         "WHERE agent_id LIKE 'poc_%' GROUP BY task_id ORDER BY 3 DESC LIMIT 8\").fetchall()\n"
         "for t, n, c in rows: print(f'{t}: submissions={n} crashes={c}')\n"
         "EOF")
    print(ssh(X86, q, timeout=30) or "(no records)")

    # ---- 5. cluster ----
    sect("5. CLUSTER (head sample)")
    npu = ssh(HEAD, f"docker exec {CONTAINER} npu-smi info 2>/dev/null | grep '910B3' | head -8")
    mems = re.findall(r"(\d+) / 65536", npu)
    if mems:
        used = [int(m) for m in mems]
        print(f"head NPU HBM MB (8 cards): min={min(used)} max={max(used)} / 65536 "
              f"({max(used)/65536:.0%} peak)")
    load = ssh(X86, "uptime | grep -oE 'load average.*'").strip()
    print(f"x86 {load}")

    print(f"\ngenerated: {datetime.now():%Y-%m-%d %H:%M:%S}")


if __name__ == "__main__":
    main()
