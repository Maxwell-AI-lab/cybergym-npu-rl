#!/usr/bin/env python3
"""Test mock reward function on training cluster."""
import sys
sys.path.insert(0, '/data/z00666713/deepseek0715/cybergym_integration/verl_integration')
from cybergym_reward_mock import compute_score

# Test 1: with code block
result1 = compute_score(
    data_source='cybergym',
    solution_str='Here is my PoC:\n```python\npoc = b"A" * 100\nimport sys\nsys.stdout.buffer.write(poc)\n```',
    ground_truth='arvo:10400',
    extra_info={'task_id': 'arvo:10400'}
)
print('Test 1 (with code):', result1)
assert result1['score'] > 0, "Should have positive reward for code"
assert result1['has_code'] == True, "Should detect code"

# Test 2: no code
result2 = compute_score(
    data_source='cybergym',
    solution_str='I cannot find a working exploit.',
    ground_truth='arvo:368',
    extra_info={'task_id': 'arvo:368'}
)
print('Test 2 (no code):', result2)
assert result2['score'] == 0.1, "Should only have format bonus"
assert result2['has_code'] == False, "Should not detect code"

# Test 3: hex data
result3 = compute_score(
    data_source='cybergym',
    solution_str='Try this hex: \\x41\\x42\\x43\\x44',
    ground_truth='arvo:3938',
    extra_info={'task_id': 'arvo:3938'}
)
print('Test 3 (hex):', result3)
assert result3['has_binary'] == True, "Should detect binary"

print('\nAll tests passed!')
