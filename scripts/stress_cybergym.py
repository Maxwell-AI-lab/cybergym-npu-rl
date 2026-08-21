#!/usr/bin/env python3
"""S4: Concurrency stress test for the CyberGym server.

Simulates the multi-turn training load: 32 concurrent trajectories each
submitting PoCs. Uses arvo:3938 (crashes on any input) so every request
exercises the real docker create/start/wait/remove path.

Usage:
    python3 stress_cybergym.py --url http://192.168.0.100:8666 \
        --concurrency 32 --per-worker 2
Run from the relay (or any host that can reach the x86 server).
"""

import argparse
import asyncio
import hashlib
import json
import statistics
import time

import httpx

SALT = "CyberGym"


def build_metadata(task_id: str, agent_id: str) -> str:
    checksum = hashlib.sha256(f"{task_id}{agent_id}{SALT}".encode()).hexdigest()
    return json.dumps(
        {"task_id": task_id, "agent_id": agent_id, "checksum": checksum, "require_flag": False}
    )


async def worker(wid: int, url: str, per_worker: int, results: list) -> None:
    async with httpx.AsyncClient(timeout=150) as client:
        for i in range(per_worker):
            agent_id = f"stress-{wid}-{i}-{time.time_ns()}"
            poc = b"STRESS" + bytes([wid % 256, i % 256]) * 16  # unique per request
            t0 = time.perf_counter()
            status = "ok"
            try:
                r = await client.post(
                    f"{url}/submit-vul",
                    data={"metadata": build_metadata("arvo:3938", agent_id)},
                    files={"file": ("poc.bin", poc)},
                )
                if r.status_code == 200:
                    exit_code = r.json().get("exit_code")
                    status = f"exit={exit_code}"
                else:
                    status = f"http{r.status_code}"
            except Exception as e:
                status = f"err:{type(e).__name__}"
            results.append((time.perf_counter() - t0, status, wid))


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://192.168.0.100:8666")
    ap.add_argument("--concurrency", type=int, default=32)
    ap.add_argument("--per-worker", type=int, default=2)
    args = ap.parse_args()

    results: list = []
    t0 = time.perf_counter()
    await asyncio.gather(*[worker(w, args.url, args.per_worker, results) for w in range(args.concurrency)])
    total = time.perf_counter() - t0

    lat = sorted(r[0] for r in results)
    statuses = [r[1] for r in results]
    crash = sum(1 for s in statuses if s == "exit=1")
    errors = sum(1 for s in statuses if s.startswith(("err", "http")))

    print(f"requests={len(results)} concurrency={args.concurrency} wall={total:.1f}s")
    print(f"latency p50={lat[len(lat)//2]:.2f}s p99={lat[int(len(lat)*0.99)]:.2f}s max={lat[-1]:.2f}s")
    print(f"crash(exit=1)={crash} errors={errors} status_sample={statuses[:5]}")
    print(f"throughput={len(results)/total:.1f} req/s")

    if errors > len(results) * 0.05:
        print("VERDICT: FAIL (>5% errors)")
    elif lat[int(len(lat) * 0.99)] > 10:
        print("VERDICT: WARN (p99>10s)")
    else:
        print("VERDICT: PASS")


if __name__ == "__main__":
    asyncio.run(main())
