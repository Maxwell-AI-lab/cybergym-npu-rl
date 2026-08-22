#!/usr/bin/env python3
"""Patch verl protocol.union_numpy_dict: on 'uid' conflict, take the gen-side
(dump) value instead of asserting equality.

Required by the resident loop: the dataset provides placeholder uids while
each round's dump carries the real collected task_ids for GRPO grouping.
"""

PATH = "/workspace-verl/verl/verl/protocol.py"

src = open(PATH).read()
old = """def union_numpy_dict(tensor_dict1: dict[str, np.ndarray], tensor_dict2: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    for key, val in tensor_dict2.items():
        if key in tensor_dict1:
"""
new = """def union_numpy_dict(tensor_dict1: dict[str, np.ndarray], tensor_dict2: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    for key, val in tensor_dict2.items():
        if key == "uid" and key in tensor_dict1:
            # offline replay: gen-side (dump) uid defines GRPO groups
            tensor_dict1[key] = val
            continue
        if key in tensor_dict1:
"""
assert src.count(old) == 1, f"anchor count {src.count(old)}"
open(PATH, "w").write(src.replace(old, new))
print("patched union_numpy_dict uid override")
