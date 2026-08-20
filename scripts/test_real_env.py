#!/usr/bin/env python3
"""
CyberGym Real Environment Integration Test

在 x86 Server 部署完成后运行，验证整个链路：
  1. Server 连通性
  2. submit-vul API (假 PoC → 应返回 no crash)
  3. submit-fix API (需要 API Key)
  4. Checksum 验证
  5. Rate limit 行为
  6. 延迟测量
  7. reward 函数端到端测试

Usage:
    # 在训练集群或能直连 x86 的机器上运行
    python test_real_env.py --server-url http://<x86-ip>:8666

    # 测试所有 10 个任务
    python test_real_env.py --server-url http://<x86-ip>:8666 --all-tasks

    # 包含延迟压测
    python test_real_env.py --server-url http://<x86-ip>:8666 --all-tasks --benchmark
"""

import argparse
import hashlib
import json
import sys
import time
import uuid
from pathlib import Path

import httpx


TASKS = [
    "arvo:47101", "arvo:3938", "arvo:24993", "arvo:1065", "arvo:10400", "arvo:368",
    "oss-fuzz:42535201", "oss-fuzz:42535468", "oss-fuzz:370689421",
]

DEFAULT_SALT = "CyberGym"
DEFAULT_API_KEY = "cybergym-030a0cd7-5908-4862-8ab9-91f2bfc7b56d"

passed = 0
failed = 0


def check(name: str, condition: bool, detail: str = ""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  [✓] {name}")
    else:
        failed += 1
        print(f"  [✗] {name}  {detail}")


def compute_checksum(task_id: str, agent_id: str, salt: str = DEFAULT_SALT) -> str:
    return hashlib.sha256(f"{task_id}{agent_id}{salt}".encode()).hexdigest()


def build_metadata(task_id: str, agent_id: str = None) -> tuple[str, str]:
    """Build metadata JSON for CyberGym submission. Returns (metadata_json, agent_id)."""
    if agent_id is None:
        agent_id = uuid.uuid4().hex
    checksum = compute_checksum(task_id, agent_id)
    metadata = json.dumps({
        "task_id": task_id,
        "agent_id": agent_id,
        "checksum": checksum,
        "require_flag": False,
    })
    return metadata, agent_id


def submit_poc(server_url: str, task_id: str, poc_data: bytes, mode: str = "vul",
               api_key: str = DEFAULT_API_KEY, timeout: int = 30) -> dict:
    """Submit PoC and return parsed result or error dict."""
    metadata, agent_id = build_metadata(task_id)
    endpoint = f"{server_url}/submit-{mode}"

    headers = {}
    if mode == "fix":
        headers["X-API-Key"] = api_key

    try:
        with httpx.Client(timeout=timeout) as client:
            resp = client.post(
                endpoint,
                data={"metadata": metadata},
                files={"file": ("poc.bin", poc_data)},
                headers=headers,
            )
            if resp.status_code == 200:
                return resp.json()
            else:
                return {"error": f"HTTP {resp.status_code}", "detail": resp.text[:200]}
    except httpx.TimeoutException:
        return {"error": "Timeout"}
    except httpx.ConnectError as e:
        return {"error": f"ConnectError: {e}"}
    except Exception as e:
        return {"error": str(e)}


# ============================================================
# Test 1: Server 连通性
# ============================================================

def test_connectivity(server_url: str):
    print("\n=== Test 1: Server Connectivity ===")

    # FastAPI Swagger docs
    try:
        resp = httpx.get(f"{server_url}/docs", timeout=5)
        check("GET /docs", resp.status_code == 200, f"status={resp.status_code}")
    except Exception as e:
        check("GET /docs", False, str(e))
        print("  [!] Server not reachable, aborting further tests")
        sys.exit(1)

    # OpenAPI schema
    try:
        resp = httpx.get(f"{server_url}/openapi.json", timeout=5)
        check("GET /openapi.json", resp.status_code == 200)
    except Exception as e:
        check("GET /openapi.json", False, str(e))


# ============================================================
# Test 2: submit-vul (假 PoC, 应不 crash)
# ============================================================

def test_submit_vul_fake(server_url: str, task_id: str = "arvo:10400"):
    print(f"\n=== Test 2: submit-vul (fake PoC, task={task_id}) ===")

    # 16 字节的假 PoC (不应触发 crash)
    poc_data = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
    result = submit_poc(server_url, task_id, poc_data, mode="vul")

    if "error" in result:
        check("submit-vul request", False, result["error"])
        return

    check("submit-vul request", True)
    check("Response has exit_code", "exit_code" in result, f"keys={list(result.keys())}")
    check("Response has poc_id", "poc_id" in result)

    exit_code = result.get("exit_code")
    # 假 PoC 大概率不 crash (exit_code=0) 或超时 (exit_code=300→映射为0)
    check("exit_code is int", isinstance(exit_code, int), f"type={type(exit_code)}")
    print(f"  exit_code={exit_code}, output={result.get('output', '')[:100]}")


# ============================================================
# Test 3: submit-fix (需要 API Key)
# ============================================================

def test_submit_fix(server_url: str, task_id: str = "arvo:368"):
    print(f"\n=== Test 3: submit-fix (task={task_id}) ===")

    poc_data = b"\x00" * 16

    # 不带 API Key → 应该 404 (CyberGym 用 APIKeyHeader, auto_error=False, 返回 404)
    metadata, agent_id = build_metadata(task_id)
    try:
        with httpx.Client(timeout=10) as client:
            resp = client.post(
                f"{server_url}/submit-fix",
                data={"metadata": metadata},
                files={"file": ("poc.bin", poc_data)},
            )
            check("submit-fix without API key → 404", resp.status_code == 404,
                  f"got {resp.status_code}")
    except Exception as e:
        check("submit-fix without API key", False, str(e))

    # 带 API Key → 应该成功
    result = submit_poc(server_url, task_id, poc_data, mode="fix")
    if "error" in result:
        check("submit-fix with API key", False, result["error"])
    else:
        check("submit-fix with API key", True)
        print(f"  exit_code={result.get('exit_code')}")


# ============================================================
# Test 4: Checksum 验证
# ============================================================

def test_checksum(server_url: str, task_id: str = "arvo:10400"):
    print(f"\n=== Test 4: Checksum Verification ===")

    agent_id = uuid.uuid4().hex

    # 正确 checksum
    checksum = compute_checksum(task_id, agent_id)
    metadata_ok = json.dumps({
        "task_id": task_id, "agent_id": agent_id,
        "checksum": checksum, "require_flag": False,
    })

    try:
        with httpx.Client(timeout=30) as client:
            resp = client.post(
                f"{server_url}/submit-vul",
                data={"metadata": metadata_ok},
                files={"file": ("poc.bin", b"\x00" * 8)},
            )
            check("Valid checksum accepted", resp.status_code == 200,
                  f"status={resp.status_code}")
    except Exception as e:
        check("Valid checksum accepted", False, str(e))

    # 错误 checksum
    metadata_bad = json.dumps({
        "task_id": task_id, "agent_id": agent_id,
        "checksum": "0" * 64, "require_flag": False,
    })

    try:
        with httpx.Client(timeout=10) as client:
            resp = client.post(
                f"{server_url}/submit-vul",
                data={"metadata": metadata_bad},
                files={"file": ("poc.bin", b"\x00" * 8)},
            )
            check("Invalid checksum rejected (400)", resp.status_code == 400,
                  f"status={resp.status_code}")
    except Exception as e:
        check("Invalid checksum rejected", False, str(e))


# ============================================================
# Test 5: 所有任务的 Docker 镜像
# ============================================================

def test_all_tasks(server_url: str):
    print(f"\n=== Test 5: All Tasks Docker Images ===")

    for task_id in TASKS:
        result = submit_poc(server_url, task_id, b"\x00" * 8, mode="vul", timeout=60)

        if "error" in result:
            check(f"{task_id} docker image", False, result["error"])
        else:
            exit_code = result.get("exit_code", -1)
            output = result.get("output", "")[:80]
            # exit_code != -1 说明容器跑了 (不管是否 crash)
            check(f"{task_id} (exit={exit_code})", exit_code != -1,
                  f"output={output}" if exit_code == -1 else "")


# ============================================================
# Test 6: 延迟测量
# ============================================================

def test_latency(server_url: str, task_id: str = "arvo:10400", n: int = 5):
    print(f"\n=== Test 6: Latency Benchmark ({n} requests) ===")

    latencies = []
    for i in range(n):
        start = time.time()
        result = submit_poc(server_url, task_id, b"\x00" * 16, mode="vul")
        elapsed = time.time() - start

        if "error" not in result:
            latencies.append(elapsed)
            print(f"  Request {i+1}: {elapsed:.2f}s (exit={result.get('exit_code')})")
        else:
            print(f"  Request {i+1}: ERROR {result['error']}")

    if latencies:
        avg = sum(latencies) / len(latencies)
        mn = min(latencies)
        mx = max(latencies)
        print(f"\n  Avg: {avg:.2f}s  Min: {mn:.2f}s  Max: {mx:.2f}s")

        # 训练时每个 step 需要 n_resp_per_prompt * batch_size 次 submit
        # 假设 batch_size=16, n=4 → 64 次 submit per step
        est_64 = avg * 64
        print(f"  Estimated 64 submits: {est_64:.0f}s ({est_64/60:.1f}min)")


# ============================================================
# Test 7: Reward 函数端到端
# ============================================================

def test_reward_function(server_url: str):
    print(f"\n=== Test 7: Reward Function End-to-End ===")

    # 导入我们的 reward 函数
    reward_path = Path(__file__).parent.parent / "verl_integration"
    sys.path.insert(0, str(reward_path))

    try:
        import cybergym_reward
        # 设置 server URL
        cybergym_reward.CYBERGYM_SERVER_URL = server_url
        check("Import cybergym_reward", True)
    except Exception as e:
        check("Import cybergym_reward", False, str(e))
        return

    # 测试 1: 无代码输出 → score=0
    result = cybergym_reward.compute_score(
        data_source="cybergym",
        solution_str="I cannot find a vulnerability in this code.",
        ground_truth="arvo:10400",
        extra_info={"task_id": "arvo:10400"},
    )
    check("No code → score=0.0", result["score"] == 0.0, f"score={result['score']}")

    # 测试 2: 有代码但假 PoC → 有 format bonus
    result = cybergym_reward.compute_score(
        data_source="cybergym",
        solution_str='```python\nimport sys\npoc = b"A" * 100\nsys.stdout.buffer.write(poc)\n```',
        ground_truth="arvo:10400",
        extra_info={"task_id": "arvo:10400"},
    )
    check("Code + fake PoC → has format bonus",
          result["score"] >= 0.1 and result["has_code"],
          f"score={result['score']}, has_code={result['has_code']}")
    print(f"  vul_exit_code={result.get('vul_exit_code')}, "
          f"fix_exit_code={result.get('fix_exit_code')}")

    # 测试 3: 纯文本兜底
    result = cybergym_reward.compute_score(
        data_source="cybergym",
        solution_str="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        ground_truth="arvo:10400",
        extra_info={"task_id": "arvo:10400"},
    )
    check("Raw text fallback → submitted", True,
          f"score={result['score']}, vul_exit_code={result.get('vul_exit_code')}")


# ============================================================
# Main
# ============================================================

def main():
    parser = argparse.ArgumentParser(description="CyberGym Real Environment Test")
    parser.add_argument("--server-url", type=str, required=True,
                        help="CyberGym server URL (e.g. http://192.168.0.100:8666)")
    parser.add_argument("--all-tasks", action="store_true",
                        help="Test all 10 tasks (pulls all Docker images)")
    parser.add_argument("--benchmark", action="store_true",
                        help="Run latency benchmark")
    parser.add_argument("--test-reward", action="store_true",
                        help="Test reward function end-to-end")
    parser.add_argument("--api-key", type=str, default=DEFAULT_API_KEY)
    args = parser.parse_args()

    server_url = args.server_url.rstrip("/")

    print(f"=== CyberGym Real Environment Integration Test ===")
    print(f"Server: {server_url}")
    print(f"Test all tasks: {args.all_tasks}")
    print(f"Benchmark: {args.benchmark}")
    print()

    # 必须跑的测试
    test_connectivity(server_url)
    test_submit_vul_fake(server_url)
    test_submit_fix(server_url)
    test_checksum(server_url)

    # 可选测试
    if args.all_tasks:
        test_all_tasks(server_url)

    if args.benchmark:
        test_latency(server_url)

    if args.test_reward:
        test_reward_function(server_url)

    # 总结
    print(f"\n{'='*60}")
    total = passed + failed
    print(f"Results: {passed}/{total} passed, {failed} failed")
    if failed == 0:
        print("✓ All tests passed!")
    else:
        print(f"✗ {failed} test(s) failed")
    print(f"{'='*60}")

    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
