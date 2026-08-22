"""BlockingRLHFDataset: dataloader-side gating for the resident-job RL loop.

The resident training job runs N rounds without restart. Each round's real
training data is produced by an EXTERNAL orchestrator (OpenHands collection
-> converter -> prep dump) and consumed via RolloutSkip. This dataset makes
the trainer WAIT for round k's dump before it can pull round k's batch:

    row 64*(k-1)  ->  block until genstep_{k:06d}/gen_batch.dp exists
                      (written by the orchestrator after collecting with
                       the weights updated in round k-1)

Env knobs:
    CYBERGYM_LOOP_DUMP_DIR   rollout_skip dump root (required to gate)
    CYBERGYM_LOOP_ROUNDS     total rounds (default inferred from len(ds)/64)
    CYBERGYM_LOOP_GBS        rows per round (default 64)
    CYBERGYM_LOOP_DISABLE=1  behave exactly like RLHFDataset (fallback)
"""

import os
import time

from verl.utils.dataset.rl_dataset import RLHFDataset


class BlockingRLHFDataset(RLHFDataset):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._dump_dir = os.environ.get(
            "CYBERGYM_LOOP_DUMP_DIR",
            "/data/dataset/openhands_traj/rollout_dump/"
            "cybergym_openhands_offline_verl_gsm8k/GBS64_N1_in12288_out1024")
        self._gbs = int(os.environ.get("CYBERGYM_LOOP_GBS", "64"))
        self._disable = os.environ.get("CYBERGYM_LOOP_DISABLE", "") == "1"
        self._last_waited = -1

    def _round_marker(self, round_idx: int) -> str:
        # genstep numbering starts at 1
        return os.path.join(self._dump_dir, f"genstep_{round_idx:06d}", "gen_batch.dp")

    def _wait_for_round(self, round_idx: int) -> None:
        marker = self._round_marker(round_idx)
        if os.path.isfile(marker):
            print(f"[BlockingDS] round {round_idx} dump ready: {marker}", flush=True)
            return
        print(f"[BlockingDS] round {round_idx} waiting for {marker} ...", flush=True)
        t0 = time.time()
        while not os.path.isfile(marker):
            time.sleep(5)
        print(f"[BlockingDS] round {round_idx} unblocked after {time.time()-t0:.0f}s", flush=True)

    def __getitem__(self, item):
        if not self._disable and self._dump_dir:
            round_idx = item // self._gbs + 1
            if item % self._gbs == 0 and round_idx != self._last_waited:
                self._last_waited = round_idx
                self._wait_for_round(round_idx)
        return super().__getitem__(item)
