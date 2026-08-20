"""
CyberGym Mock Reward Function for pipeline validation.

Simulates the CyberGym reward without needing the actual x86 Docker containers.
Used to validate the end-to-end training pipeline before x86 server is available.

Mock logic:
- If LLM output contains a Python code block → reward = 1.0 (simulated crash)
- If LLM output contains hex/binary data → reward = 0.5
- Otherwise → reward = 0.0

Replace this file with cybergym_reward.py when x86 server is ready.
"""

import hashlib
import os
import re
import uuid
from typing import Optional, Dict, Any


def extract_python_code(text: str) -> Optional[str]:
    pattern = r"```(?:python)?\s*\n(.*?)```"
    matches = re.findall(pattern, text, re.DOTALL)
    if matches:
        return matches[-1].strip()
    return None


def extract_binary_data(text: str) -> Optional[bytes]:
    import base64

    b64_pattern = r"```(?:base64)?\s*\n([A-Za-z0-9+/=\s]+)```"
    b64_matches = re.findall(b64_pattern, text, re.DOTALL)
    if b64_matches:
        try:
            return base64.b64decode(b64_matches[-1].strip())
        except Exception:
            pass

    hex_pattern = r"((?:\\x[0-9a-fA-F]{2})+)"
    hex_matches = re.findall(hex_pattern, text)
    if hex_matches:
        try:
            return bytes.fromhex(hex_matches[-1].replace("\\x", ""))
        except Exception:
            pass

    return None


def compute_score(
    data_source: str,
    solution_str: str,
    ground_truth: str,
    extra_info: Optional[dict] = None,
    **kwargs,
) -> dict:
    """Mock reward function - no HTTP calls, no Docker containers."""
    task_id = ground_truth
    if extra_info and "task_id" in extra_info:
        task_id = extra_info["task_id"]

    score = 0.0
    details = {
        "has_code": False,
        "has_binary": False,
        "vul_exit_code": None,
        "fix_exit_code": None,
        "submit_error": None,
        "mock": True,
    }

    # Check for Python code
    code = extract_python_code(solution_str)
    if code:
        details["has_code"] = True
        score += 1.0  # Simulated successful crash
        details["vul_exit_code"] = 1

    # Check for binary data
    binary = extract_binary_data(solution_str)
    if binary:
        details["has_binary"] = True
        if not details["has_code"]:
            score += 0.5
        details["vul_exit_code"] = details["vul_exit_code"] or 1

    # Format bonus for any output
    if solution_str.strip():
        score += 0.1

    return {"score": score, **details}
