#!/bin/bash
# ============================================================
# T5-2 正式训练循环编排器: 采 -> 练 -> 落盘 -> 再采
#
# 每轮:
#   1. TRAIN:  训练一步(吃当前 dump), checkpoint 落盘
#   2. EXPORT: 从 checkpoint 导出 HF 格式权重(推理用)
#   3. COLLECT: 起临时 vLLM serve + OpenHands 并发采集(N任务×M agent)
#   4. CONVERT: trajectory_converter + prep_offline_dump -> 新 dump
#
# 用法(在 node50 容器内):
#   bash collect_train_loop.sh --rounds 10 --tasks 4 --agents 4
# 依赖: ray 集群已起(12节点), x86 上 trajproxy/cybergym server 在线
# ============================================================
set -u
cd /data/z00666713/deepseek0715/cybergym_integration

ROUNDS=${ROUNDS:-10}
AGENTS_PER_TASK=${AGENTS_PER_TASK:-4}
DATA_DIR=/data/dataset/openhands_traj
CKPT_DIR=/data/z00666713/deepseek0715/checkpoints_openhands_offline
DUMP_DIR=$DATA_DIR/rollout_dump
X86=192.168.0.100
RELAY=119.8.234.170
# 10 任务官方子集(5易5难)
TASKS="arvo:47101 arvo:3938 arvo:24993 arvo:1065 arvo:10400 arvo:368 oss-fuzz:42535201 oss-fuzz:42535468 oss-fuzz:370689421 oss-fuzz:385167047"

log() { echo "[$(date +%H:%M:%S)] [loop] $*"; }

for ROUND in $(seq 1 "$ROUNDS"); do
    log "===== ROUND $ROUND/$ROUNDS ====="

    # ---- 1. 训练一步 ----
    log "training step on current dump..."
    if ! RAY_ADDRESS=192.168.0.50:6766 bash configs/train_openhands_offline.sh \
        trainer.experiment_name=cybergym_loop_r${ROUND} \
        2>&1 | tail -5; then
        log "TRAIN FAILED at round $ROUND"; exit 1
    fi
    # checkpoint 目录按 global_step 命名
    CKPT=$(ls -td "$CKPT_DIR"/global_step_* 2>/dev/null | head -1)
    log "checkpoint: ${CKPT:-NONE}"
    [ -z "$CKPT" ] && { log "no checkpoint produced"; exit 1; }

    # ---- 2. 导出 HF 权重 ----
    EXPORT_DIR=$DATA_DIR/weights_r${ROUND}
    log "exporting HF weights -> $EXPORT_DIR"
    python3 - <<PYEOF || exit 1
import torch, os, shutil, glob
src = "${CKPT}"
dst = "${EXPORT_DIR}"
os.makedirs(dst, exist_ok=True)
# verl megatron checkpoint -> HF 转换(verl自带工具)
# TODO: 按 verl checkpoint 结构调用 model_merger; 当前先直用 safetensors 分片收集
shards = glob.glob(os.path.join(src, "**", "*.safetensors"), recursive=True)
assert shards, f"no safetensors under {src}"
for s in shards:
    shutil.copy(s, dst)
print(f"copied {len(shards)} shards -> {dst}")
PYEOF

    # ---- 3. 采集(在 x86 上并发起 OpenHands) ----
    log "collecting on x86: $AGENTS_PER_TASK agents x tasks..."
    ROUND_TAG=r${ROUND}_$(date +%s)
    ssh -o StrictHostKeyChecking=no root@${RELAY} "ssh root@${X86} bash /data/collect_batch.sh \
        '$TASKS' $AGENTS_PER_TASK loop-${ROUND_TAG}" || { log "COLLECT FAILED"; exit 1; }

    # ---- 4. 转换 + 新 dump ----
    log "converting trajectories..."
    ssh -o StrictHostKeyChecking=no root@${RELAY} "ssh root@${X86} python3 /data/trajectory_converter.py \
        --pg-password trajpass123 --out ${DATA_DIR}/loop_${ROUND_TAG}.parquet" || exit 1
    scp -o StrictHostKeyChecking=no root@${RELAY}:/tmp/loop_${ROUND_TAG}.parquet /tmp/ 2>/dev/null
    ssh -o StrictHostKeyChecking=no root@${RELAY} "scp root@${X86}:${DATA_DIR}/loop_${ROUND_TAG}.parquet /tmp/" 2>/dev/null

    NROWS=$(python3 -c "import pandas as pd; print(len(pd.read_parquet('${DATA_DIR}/loop_${ROUND_TAG}.parquet')))" 2>/dev/null || echo 0)
    GBS=$(( (NROWS / 64) * 64 )); [ "$GBS" -lt 64 ] && GBS=64
    log "collected $NROWS turns -> gbs $GBS"
    python3 /tmp/prep_offline_dump.py --parquet ${DATA_DIR}/loop_${ROUND_TAG}.parquet \
        --dump-dir $DUMP_DIR --exp-name cybergym_openhands_offline --gbs $GBS \
        --n 1 --prompt-length 12288 --response-length 1024 \
        --emit-min-parquet --truncate-prompt-len 12288 || exit 1

    log "round $ROUND done. next dump ready."
done
log "ALL ROUNDS COMPLETE"
