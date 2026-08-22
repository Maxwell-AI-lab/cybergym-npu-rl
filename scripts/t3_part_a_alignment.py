#!/usr/bin/env python3
"""T3 Part A: token-level alignment check for trajproxy TITO sessions.

For each consecutive request pair (k, k+1) in a session, verify that
full_conversation_token_ids[k+1] extends full_conversation_token_ids[k]
(i.e. the next prompt re-tokenizes the previous conversation identically).

Outputs per session:
  - pairs checked
  - exact-prefix-extension rate
  - where divergences happen (turn index, position)

Runs on x86 with only stdlib (psql via docker exec).
"""

import re
import subprocess
import sys

SESSIONS = sys.argv[1:] or ["e2e-optimized-001", "e2e-official-001", "e2e-fixed-001"]


def query(session):
    sql = (
        "SELECT d.full_conversation_token_ids::text, d.response_ids::text "
        "FROM request_details_active d JOIN request_metadata m ON m.unique_id = d.unique_id "
        f"WHERE m.session_id = '{session}' ORDER BY d.created_at;"
    )
    out = subprocess.run(
        ["docker", "exec", "traj_db", "psql", "-U", "traj", "-d", "traj_proxy", "-At", "-c", sql],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    rows = []
    for line in out.splitlines():
        parts = line.split("|")
        if len(parts) != 2:
            continue
        full = [int(x) for x in re.findall(r"-?\d+", parts[0])]
        resp = [int(x) for x in re.findall(r"-?\d+", parts[1])]
        rows.append((full, resp))
    return rows


def common_prefix_len(a, b):
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


for sess in SESSIONS:
    rows = query(sess)
    if not rows:
        print(f"[{sess}] no data")
        continue
    total = len(rows)
    exact = 0
    details = []
    for k in range(total - 1):
        prev_full, prev_resp = rows[k]
        next_full, _ = rows[k + 1]
        cpl = common_prefix_len(prev_full, next_full)
        is_ext = cpl == len(prev_full)
        if is_ext:
            exact += 1
        else:
            details.append((k, len(prev_full), cpl, len(prev_full) - cpl))
    print(f"[{sess}] requests={total} pairs={total-1} exact_extension={exact}/{total-1}")
    for k, plen, cpl, gap in details[:8]:
        print(f"    turn {k}->{k+1}: prev_len={plen} common_prefix={cpl} diverge_at_tail={gap} tokens")
    # token identity of response boundary: does next_full contain prev_resp right after prefix?
    contain = 0
    for k in range(total - 1):
        prev_full, prev_resp = rows[k]
        next_full, _ = rows[k + 1]
        if prev_resp and next_full[len(prev_full):len(prev_full) + len(prev_resp)] == prev_resp:
            contain += 1
    print(f"    response_ids replayed verbatim in next prompt: {contain}/{total-1}")
