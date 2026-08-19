#!/usr/bin/env python3
"""
Test CyberGym reward function locally (without verl).

Tests:
1. Code extraction from LLM output
2. PoC submission to CyberGym server
3. Reward computation end-to-end

Usage:
    # Basic test (no server needed)
    python test_reward.py --offline

    # Full test with CyberGym server
    CYBERGYM_SERVER_URL=http://localhost:8666 python test_reward.py

    # Test with specific task
    CYBERGYM_SERVER_URL=http://localhost:8666 python test_reward.py --task-id arvo:10400
"""

import argparse
import json
import sys
from pathlib import Path

# Add parent to path
sys.path.insert(0, str(Path(__file__).parent.parent / "verl_integration"))
from cybergym_reward import (
    compute_score,
    extract_python_code,
    extract_binary_data,
    _execute_poc_script,
    submit_to_cybergym,
)


def test_extract_python_code():
    """Test Python code extraction from various LLM output formats."""
    print("=== Test: extract_python_code ===")

    # Test 1: Standard ```python block
    text1 = """Here's my PoC:

```python
import struct
poc = b"A" * 100 + struct.pack("<I", 0xdeadbeef)
import sys
sys.stdout.buffer.write(poc)
```

This should trigger a buffer overflow."""
    code1 = extract_python_code(text1)
    assert code1 is not None, "Should extract Python code"
    assert "struct.pack" in code1, "Should contain the code"
    print(f"  [✓] Standard block: extracted {len(code1)} chars")

    # Test 2: ``` without language tag
    text2 = """Try this:
```
print(b"\\x41\\x42\\x43" * 50)
```
"""
    code2 = extract_python_code(text2)
    assert code2 is not None, "Should extract code without language tag"
    print(f"  [✓] No language tag: extracted {len(code2)} chars")

    # Test 3: Multiple code blocks (should return last)
    text3 = """First attempt:
```python
poc = b"A" * 10
```

That didn't work. Let me try:
```python
poc = b"A" * 100
```
"""
    code3 = extract_python_code(text3)
    assert code3 is not None and "100" in code3, "Should return last code block"
    print(f"  [✓] Multiple blocks: returned last block")

    # Test 4: No code block
    text4 = "This is just text with no code blocks."
    code4 = extract_python_code(text4)
    assert code4 is None, "Should return None for no code"
    print(f"  [✓] No code block: returned None")

    print()


def test_extract_binary_data():
    """Test binary data extraction."""
    print("=== Test: extract_binary_data ===")

    # Hex string
    data1 = extract_binary_data("The PoC is: \\x41\\x42\\x43\\x44")
    assert data1 == b"ABCD", f"Expected b'ABCD', got {data1}"
    print(f"  [✓] Hex string: {data1}")

    # Base64
    data2 = extract_binary_data("```base64\nQUJDRA==\n```")
    assert data2 == b"ABCD", f"Expected b'ABCD', got {data2}"
    print(f"  [✓] Base64: {data2}")

    print()


def test_execute_poc_script():
    """Test PoC script execution."""
    print("=== Test: execute_poc_script ===")

    code = """
import sys
sys.stdout.buffer.write(b"HELLO_POC")
"""
    data = _execute_poc_script(code)
    assert data == b"HELLO_POC", f"Expected b'HELLO_POC', got {data}"
    print(f"  [✓] Script execution: {data}")

    print()


def test_compute_score_offline():
    """Test compute_score without server (should handle connection error gracefully)."""
    print("=== Test: compute_score (offline) ===")

    # LLM output with a code block
    solution = """Let me analyze the vulnerability.

Based on the buffer overflow in the `parse_input` function, I'll craft a PoC:

```python
import sys
# Overflow the 64-byte buffer and overwrite the return address
poc = b"A" * 64 + b"\\x42" * 8 + b"\\x43" * 8
sys.stdout.buffer.write(poc)
```
"""
    result = compute_score(
        data_source="cybergym",
        solution_str=solution,
        ground_truth="arvo:10400",
        extra_info={"task_id": "arvo:10400", "difficulty": "level1"},
    )
    print(f"  Result: {json.dumps(result, indent=2, default=str)}")
    assert "score" in result, "Should have score"
    assert result["has_code"], "Should detect code"
    # Server is unreachable, so submit_error should be set
    if result.get("submit_error"):
        print(f"  [✓] Server unreachable (expected): {result['submit_error'][:80]}")
    else:
        print(f"  [✓] Got reward: {result['score']}")

    # Test with no code
    result2 = compute_score(
        data_source="cybergym",
        solution_str="I couldn't find a working exploit.",
        ground_truth="arvo:10400",
    )
    assert result2["score"] == 0.0, "No code should give 0 reward"
    assert not result2["has_code"], "Should not detect code"
    print(f"  [✓] No code output: score={result2['score']}")

    print()


def test_compute_score_live(task_id: str = "arvo:10400"):
    """Test compute_score with a real CyberGym server."""
    print(f"=== Test: compute_score (live, task={task_id}) ===")

    # A simple PoC that's unlikely to crash (should get 0 reward)
    solution_bad = """
```python
import sys
sys.stdout.buffer.write(b"A" * 4)
```
"""
    result = compute_score(
        data_source="cybergym",
        solution_str=solution_bad,
        ground_truth=task_id,
        extra_info={"task_id": task_id},
    )
    print(f"  Bad PoC result: {json.dumps(result, indent=2, default=str)}")

    print()


def main():
    parser = argparse.ArgumentParser(description="Test CyberGym reward function")
    parser.add_argument("--offline", action="store_true", help="Run offline tests only")
    parser.add_argument("--task-id", type=str, default="arvo:10400",
                        help="Task ID for live test")
    args = parser.parse_args()

    test_extract_python_code()
    test_extract_binary_data()
    test_execute_poc_script()
    test_compute_score_offline()

    if not args.offline:
        test_compute_score_live(args.task_id)

    print("=== All tests passed ===")


if __name__ == "__main__":
    main()
