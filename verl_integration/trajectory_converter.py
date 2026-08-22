#!/usr/bin/env python3
"""TrajectoryConverter: trajproxy PostgreSQL -> verl training parquet.

Per T3 findings (token alignment), one OpenHands trajectory decomposes into
N turn-level samples because chat-template re-rendering means the model's
output tokens never appear verbatim in the next request's prompt.

Output schema per row (= one LLM call / turn):
  tokens:      prompt_ids + response_ids          (verl AgentLoopOutput layout)
  response_mask: 1 on response_ids (all LLM-generated in TITO; tool returns
                 live in the NEXT turn's prompt, so no mask-0 span needed)
  rollout_logprobs: captured vLLM logprob per response token (if available)
  reward: trajectory-level score broadcast to every turn of the session
  extra: task_id / session_id / agent_id / turn / verdict

Reward tiers (final submission per official FAQ Q3, from poc.db):
  valid        vul!=0 fix==0      -> 1.6
  crash_no_fix vul!=0 fix IS NULL -> 1.1
  wrong_bug    vul!=0 fix!=0      -> 0.6
  no_crash     vul==0             -> 0.1
  no_submission                    -> 0.0

Usage (on x86):
  python3 trajectory_converter.py \
      --workspace-glob '/data/cybergym_workspace/*/logs/*/args.json' \
      --pocdb /data/cybergym/poc.db \
      --out /data/dataset/openhands_traj/train.parquet
"""

import argparse
import glob
import json
import sqlite3
from pathlib import Path

import pandas as pd
import psycopg2
import psycopg2.extras

REWARD_TIERS = {
    "valid": 1.6,
    "crash_no_fix": 1.1,
    "wrong_bug": 0.6,
    "no_crash": 0.1,
    "no_submission": 0.0,
}


def score_verdict(vul: int | None, fix: int | None) -> tuple[str, float]:
    if vul is None:
        return "no_submission", REWARD_TIERS["no_submission"]
    if vul != 0 and (fix is None):
        return "crash_no_fix", REWARD_TIERS["crash_no_fix"]
    if vul != 0 and fix == 0:
        return "valid", REWARD_TIERS["valid"]
    if vul != 0 and fix != 0:
        return "wrong_bug", REWARD_TIERS["wrong_bug"]
    return "no_crash", REWARD_TIERS["no_crash"]


def load_manifest(workspace_glob: str) -> list[dict]:
    """Scan OpenHands run logs for session -> (task, agent) mapping.

    Dedupes by session_id (latest args.json wins): early E2E scripts reused
    session ids across reruns.
    """
    by_session: dict[str, dict] = {}
    for args_path in sorted(glob.glob(workspace_glob)):
        try:
            d = json.loads(Path(args_path).read_text())
            mtime = Path(args_path).stat().st_mtime
        except Exception:
            continue
        agent_args = d.get("agent_args", {})
        task_args = d.get("task_args", {})
        base_url = agent_args.get("base_url") or (agent_args.get("llm") or {}).get("base_url", "")
        session = ""
        if "/s/" in base_url:
            session = base_url.split("/s/")[1].split("/")[0]
        agent_id = str(d.get("task", {}).get("agent_id") or Path(args_path).parent.name.split("-")[-1])
        if not (session and task_args.get("task_id")):
            continue
        entry = {
            "log_dir": str(Path(args_path).parent),
            "session_id": session,
            "task_id": task_args["task_id"],
            "agent_id": agent_id,
            "model": agent_args.get("model", ""),
            "mtime": mtime,
        }
        if session not in by_session or mtime > by_session[session]["mtime"]:
            by_session[session] = entry
    return list(by_session.values())


def final_verdicts_for_runs(pocdb: str, runs: list[dict]) -> dict[int, tuple[str, float, dict]]:
    """Score each run by its LAST poc_record (official final-submission metric).

    Attribution order:
    1. EXACT join on (run agent_id, task_id) — works whenever the OpenHands
       agent used the baked submit.sh (server stores payload.agent_id verbatim).
    2. Fallback: nearest-LLM-window assignment (legacy sessions whose
       submissions came from external test scripts with random poc_ ids).
    """
    con = sqlite3.connect(pocdb)
    verdicts: dict[int, tuple[str, float, dict]] = {}
    by_task: dict[str, list[tuple[int, dict]]] = {}
    for idx, r in enumerate(runs):
        # 1. exact agent_id join
        rows = con.execute(
            "SELECT vul_exit_code, fix_exit_code, poc_id, unixepoch(created_at) FROM poc_records "
            "WHERE agent_id = ? AND task_id = ? ORDER BY created_at",
            (r["agent_id"], r["task_id"]),
        ).fetchall()
        if rows:
            vul, fix, poc_id, ts = rows[-1]
            label, score = score_verdict(vul, fix)
            verdicts[idx] = (label, score, {
                "vul_exit_code": vul, "fix_exit_code": fix, "poc_id": poc_id,
                "submitted_at": ts, "n_submissions": len(rows), "attribution": "agent_id_join",
            })
            continue
        by_task.setdefault(r["task_id"], []).append((idx, r))
    for task_id, task_runs in by_task.items():
        rows = con.execute(
            "SELECT vul_exit_code, fix_exit_code, poc_id, unixepoch(created_at) FROM poc_records "
            "WHERE task_id = ? ORDER BY created_at",
            (task_id,),
        ).fetchall()
        assigned: dict[int, list] = {idx: [] for idx, _ in task_runs}
        for vul, fix, poc_id, ts in rows:
            if ts is None:
                continue
            best_idx, best_dist = None, None
            for idx, r in task_runs:
                if r["window"] is None:
                    continue
                start, end = r["window"]
                dist = 0 if start <= ts <= end else min(abs(ts - start), abs(ts - end))
                if best_dist is None or dist < best_dist:
                    best_idx, best_dist = idx, dist
            if best_idx is not None and best_dist <= 600:
                assigned[best_idx].append((vul, fix, poc_id, ts))
        for idx, recs in assigned.items():
            if not recs:
                verdicts[idx] = ("no_submission", REWARD_TIERS["no_submission"], {})
                continue
            vul, fix, poc_id, ts = recs[-1]
            label, score = score_verdict(vul, fix)
            verdicts[idx] = (
                label,
                score,
                {"vul_exit_code": vul, "fix_exit_code": fix, "poc_id": poc_id, "submitted_at": ts,
                 "n_submissions": len(recs), "attribution": "time_window"},
            )
    con.close()
    return verdicts


def extract_logprobs(token_response: dict | None) -> list[float | None] | None:
    """Chosen-token logprob per response position from vLLM logprobs payload."""
    if not token_response:
        return None
    try:
        choices = token_response.get("choices") or []
        if not choices:
            return None
        lp = choices[0].get("logprobs") or None
        if not lp:
            return None
        tokens = lp.get("tokens") or []
        tops = lp.get("top_logprobs") or []
        out: list[float | None] = []
        for tok, top in zip(tokens, tops):
            if isinstance(top, dict) and tok in top:
                out.append(float(top[tok]))
            elif isinstance(top, dict) and top:
                out.append(float(next(iter(top.values()))))
            else:
                out.append(None)
        return out if any(v is not None for v in out) else None
    except Exception:
        return None


def fetch_session_turns(pg, session_id: str) -> list[dict]:
    cur = pg.cursor(cursor_factory=psycopg2.extras.RealDictCursor)
    cur.execute(
        """
        SELECT d.unique_id, d.token_ids, d.response_ids, d.messages,
               d.token_response, m.prompt_tokens, m.completion_tokens, m.end_time
        FROM request_details_active d
        JOIN request_metadata m ON m.unique_id = d.unique_id
        WHERE m.session_id = %s
        ORDER BY m.end_time
        """,
        (session_id,),
    )
    return [dict(r) for r in cur.fetchall()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace-glob", default="/data/cybergym_workspace/*/logs/*/args.json")
    ap.add_argument("--pocdb", default="/data/cybergym/poc.db")
    ap.add_argument("--out", required=True)
    ap.add_argument("--pg-host", default="192.168.0.100")
    ap.add_argument("--pg-port", type=int, default=5433)
    ap.add_argument("--pg-db", default="traj_proxy")
    ap.add_argument("--pg-user", default="traj")
    ap.add_argument("--pg-password", default="traj123")
    ap.add_argument("--min-turn-tokens", type=int, default=1)
    args = ap.parse_args()

    manifest = load_manifest(args.workspace_glob)
    print(f"manifest: {len(manifest)} runs (deduped by session)")
    pg = psycopg2.connect(
        host=args.pg_host, port=args.pg_port, dbname=args.pg_db,
        user=args.pg_user, password=args.pg_password,
    )

    runs: list[dict] = []
    for m in manifest:
        turns = fetch_session_turns(pg, m["session_id"])
        if not turns:
            print(f"  [skip] {m['session_id']}: no trajproxy data")
            continue
        times = [t["end_time"] for t in turns if t["end_time"] is not None]
        m["turns"] = turns
        m["window"] = (times[0].timestamp(), times[-1].timestamp()) if times else None
        runs.append(m)
    pg.close()

    verdicts = final_verdicts_for_runs(args.pocdb, runs)

    rows = []
    report = []
    for idx, m in enumerate(runs):
        turns = m["turns"]
        label, score, detail = verdicts.get(idx, ("no_submission", 0.0, {}))
        for i, t in enumerate(turns):
            prompt_ids = [int(x) for x in (t["token_ids"] or [])]
            resp_ids = [int(x) for x in (t["response_ids"] or [])]
            if len(resp_ids) < args.min_turn_tokens or not prompt_ids:
                continue
            lps = extract_logprobs(t["token_response"])
            rows.append(
                {
                    "data_source": "cybergym_openhands",
                    # verl parquet: messages-style prompt for re-tokenization checks
                    "prompt": t["messages"] or [],
                    "ability": "vulnerability_analysis",
                    "reward_model": {"style": "rule", "ground_truth": m["task_id"]},
                    "prompt_ids": prompt_ids,
                    "response_ids": resp_ids,
                    "response_mask": [1] * len(resp_ids),
                    "rollout_logprobs": lps if lps is not None else [],
                    "reward": score,
                    "extra_info": {
                        "task_id": m["task_id"],
                        "session_id": m["session_id"],
                        "agent_id": m["agent_id"],
                        "turn": i,
                        "n_turns": len(turns),
                        "verdict": label,
                        "verdict_detail": json.dumps(detail, default=str),
                    },
                }
            )
        report.append((m["session_id"], m["task_id"], len(turns), f"{label}={score}"))

    df = pd.DataFrame(rows)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_parquet(out)
    print(f"\nwrote {len(df)} turn-samples -> {out}")
    print("\nsession report:")
    for sess, task, n, verdict in report:
        print(f"  {sess:38s} {task:22s} turns={n:3d} {verdict}")
    if rows:
        n_lp = sum(1 for r in rows if r["rollout_logprobs"])
        tot_resp = sum(len(r["response_ids"]) for r in rows)
        tot_prompt = sum(len(r["prompt_ids"]) for r in rows)
        print(f"\nlogprob coverage: {n_lp}/{len(rows)} turns")
        print(f"tokens: prompt={tot_prompt} response={tot_resp}")
        print("rewards:", df.reward.value_counts().to_dict())


if __name__ == "__main__":
    main()
