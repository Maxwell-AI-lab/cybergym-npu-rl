#!/usr/bin/env python3
"""Prepare a RolloutSkip dump directory from the converted trajectory parquet.

This lets the standard verl RayPPOTrainer (agent-loop async mode) consume
pre-collected OpenHands trajectories: with rollout.skip.enable=true and this
dump present, generate_sequences() loads our DataProto instead of calling
vLLM, so the whole GRPO path (old_log_prob recompute -> advantage -> actor
update) runs on real trajectory data without any rollout endpoint.

Run inside the training container (needs verl + torch):
  PYTHONPATH=/workspace-verl/verl python3 prep_offline_dump.py \
      --parquet /data/dataset/openhands_traj/batch2.parquet \
      --dump-dir /data/dataset/openhands_traj/rollout_dump \
      --exp-name cybergym_openhands_offline --project-name verl_gsm8k \
      --gbs 131 --n 1 --prompt-length 24576 --response-length 1024
"""

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd
import torch
from tensordict import TensorDict

from verl.protocol import DataProto


def pad_left(ids: list[int], length: int, pad: int = 0) -> torch.Tensor:
    out = torch.full((length,), pad, dtype=torch.int64)
    out[length - len(ids):] = torch.tensor(ids, dtype=torch.int64)
    return out


def pad_right(ids: list[int], length: int, pad: int = 0) -> torch.Tensor:
    out = torch.full((length,), pad, dtype=torch.int64)
    out[:len(ids)] = torch.tensor(ids, dtype=torch.int64)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--parquet", required=True)
    ap.add_argument("--dump-dir", required=True)
    ap.add_argument("--exp-name", required=True)
    ap.add_argument("--project-name", default="verl_gsm8k")
    ap.add_argument("--gbs", type=int, required=True)
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--prompt-length", type=int, required=True)
    ap.add_argument("--response-length", type=int, required=True)
    ap.add_argument("--gen-step", type=int, default=1)
    ap.add_argument("--emit-min-parquet", action="store_true",
                    help="also write a stripped parquet (no token-array columns) for the RLHFDataset")
    ap.add_argument("--truncate-prompt-len", type=int, default=0,
                    help="left-truncate prompts longer than this (keep the tail, like verl's own truncation)")
    args = ap.parse_args()

    df = pd.read_parquet(args.parquet)
    if args.truncate_prompt_len > 0:
        n_trunc = 0
        new_prompts = []
        for p in df["prompt_ids"]:
            p = list(p)
            if len(p) > args.truncate_prompt_len:
                p = p[len(p) - args.truncate_prompt_len:]
                n_trunc += 1
            new_prompts.append(p)
        df["prompt_ids"] = new_prompts
        print(f"left-truncated {n_trunc} prompts to <= {args.truncate_prompt_len}")
    if len(df) > args.gbs:
        # trim to gbs: drop zero-reward rows first, then lowest-reward, from the tail
        order = sorted(range(len(df)), key=lambda i: (df["reward"].iloc[i], -i))
        drop_idx = order[: len(df) - args.gbs]
        df = df.drop(index=drop_idx).reset_index(drop=True)
        print(f"trimmed {len(drop_idx)} rows (zero/low-reward first) -> {len(df)}")
    assert len(df) == args.gbs, f"parquet has {len(df)} rows, gbs={args.gbs}"
    max_p = max(len(r) for r in df["prompt_ids"])
    max_r = max(len(r) for r in df["response_ids"])
    assert max_p <= args.prompt_length, f"prompt too long: {max_p}"
    assert max_r <= args.response_length, f"response too long: {max_r}"

    PL, RL = args.prompt_length, args.response_length
    bsz = len(df)
    prompts = torch.stack([pad_left(list(r), PL) for r in df["prompt_ids"]])
    responses = torch.stack([pad_right(list(r), RL) for r in df["response_ids"]])
    resp_mask = torch.stack([pad_right(list(m), RL) for m in df["response_mask"]])
    prompt_attn = (prompts != 0).long()
    # prompt token id 0 could be a real token; use length-based masks instead
    prompt_attn = torch.zeros_like(prompts)
    resp_attn = torch.zeros_like(responses)
    for i in range(bsz):
        lp = len(df["prompt_ids"].iloc[i])
        lr = len(df["response_ids"].iloc[i])
        prompt_attn[i, PL - lp:] = 1
        resp_attn[i, :lr] = 1
    response_mask = resp_mask * resp_attn
    attention_mask = torch.cat([prompt_attn, resp_attn], dim=1)
    input_ids = torch.cat([prompts, responses], dim=1)
    position_ids = (attention_mask.cumsum(dim=1) - 1).clamp(min=0)

    # rm_scores: trajectory reward at each row's last valid response position
    rm_scores = torch.zeros_like(response_mask, dtype=torch.float32)
    for i in range(bsz):
        lr = int(resp_attn[i].sum().item())
        rm_scores[i, lr - 1] = float(df["reward"].iloc[i])

    # rollout_logprobs (captured from vLLM, right-padded with 0.0) -> T3-B reconciliation
    has_lp = all(len(list(r)) > 0 for r in df["rollout_logprobs"])
    optional = {}
    if has_lp:
        lp = torch.zeros((bsz, RL), dtype=torch.float32)
        for i in range(bsz):
            vals = [v if v is not None else 0.0 for v in list(df["rollout_logprobs"].iloc[i])]
            lp[i, :len(vals)] = torch.tensor(vals, dtype=torch.float32)
        optional["rollout_log_probs"] = lp

    batch = TensorDict(
        {
            "prompts": prompts,
            "responses": responses,
            "response_mask": response_mask,
            "input_ids": input_ids,
            "attention_mask": attention_mask,
            "position_ids": position_ids,
            "rm_scores": rm_scores,
            **optional,
        },
        batch_size=bsz,
    )

    # uid = task_id -> GRPO groups by task
    uid = np.array([e["task_id"] for e in df["extra_info"]], dtype=object)
    non_tensor = {
        "uid": uid,
        "__num_turns__": np.array([e.get("n_turns", 1) for e in df["extra_info"]], dtype=np.int32),
        "multi_modal_inputs": np.array([{} for _ in range(bsz)], dtype=object),
        "data_source": np.array(["cybergym_openhands"] * bsz, dtype=object),
    }
    meta = {"timing": {}, "global_steps": 1}

    gen_out = DataProto(batch=batch, non_tensor_batch=non_tensor, meta_info=meta)
    # new_batch only needs to be loadable; its contents are replaced/discarded
    new_batch = DataProto(
        batch=TensorDict({"prompts": prompts.clone()}, batch_size=bsz),
        non_tensor_batch={"uid": uid.copy()},
        meta_info={"timing": {}},
    )

    sub = f"{args.exp_name}_{args.project_name}/GBS{args.gbs}_N{args.n}_in{args.prompt_length}_out{args.response_length}"
    step_dir = Path(args.dump_dir) / sub / f"genstep_{args.gen_step:06d}"
    step_dir.mkdir(parents=True, exist_ok=True)
    gen_out.save_to_disk(step_dir / "gen_batch.dp")
    new_batch.save_to_disk(step_dir / "new_batch.dp")
    (step_dir / "meta.json").write_text(json.dumps({"global_steps": 1, "gen_steps": args.gen_step}))
    with open(step_dir.parent / "train_step__gen_step.txt", "a") as f:
        f.write(f"1 {args.gen_step}\n")

    print(f"dumped {bsz} samples -> {step_dir}")
    print(f"prompt max={max_p}/{PL} response max={max_r}/{RL}")
    print(f"uid groups: {dict(zip(*np.unique(uid, return_counts=True)))}")
    print(f"rewards: {dict(zip(*np.unique(rm_scores.sum(1).tolist(), return_counts=True)))}")
    print(f"rollout_log_probs included: {has_lp}")

    if args.emit_min_parquet:
        min_path = Path(args.parquet).with_name(Path(args.parquet).stem + "_min.parquet")
        min_df = df[["data_source", "prompt", "ability", "reward_model", "extra_info"]].copy()
        # dataset-provided uid = task_id -> GRPO groups by task (requires the
        # ray_trainer.py uid-respect patch)
        min_df["uid"] = [e["task_id"] for e in df["extra_info"]]
        min_df.to_parquet(min_path)
        print(f"stripped dataset parquet -> {min_path} ({len(min_df)} rows, uid=task_id)")


if __name__ == "__main__":
    main()
