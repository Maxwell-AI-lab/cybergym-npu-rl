#!/usr/bin/env python3
"""Patch ray_trainer.py fit() to respect dataset-provided uid (for RolloutSkip
offline replay: uid in the dumped gen_batch must equal the batch's uid).

Only touches the training-loop assignment (line ~1367), not the validation one.
"""

import re

PATH = "/workspace-verl/verl/verl/trainer/ppo/ray_trainer.py"

src = open(PATH).read()
old = """                # add uid to batch
                batch.non_tensor_batch["uid"] = np.array(
                    [str(uuid.uuid4()) for _ in range(len(batch.batch))], dtype=object
                )
"""
new = """                # add uid to batch (respect dataset-provided uid, e.g. offline replay
                # where the dumped gen_batch carries uid for GRPO grouping)
                if "uid" not in batch.non_tensor_batch:
                    batch.non_tensor_batch["uid"] = np.array(
                        [str(uuid.uuid4()) for _ in range(len(batch.batch))], dtype=object
                    )
"""
assert src.count(old) == 1, f"pattern count = {src.count(old)}"
open(PATH, "w").write(src.replace(old, new))
print("patched", PATH)
