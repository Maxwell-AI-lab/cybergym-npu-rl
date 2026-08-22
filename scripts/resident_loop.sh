#!/bin/bash
# ============================================================
# 常驻循环编排器 v2 (relay 上运行)
#
# 前置: 训练作业已用 BlockingRLHFDataset 发射(N轮), ray 集群在
# 流程(每轮 k=2..N):
#   1. 等训练日志出现 "training/global_step: k-1"
#   2. 停顿等待 update_weights 同步完成(权重已入引擎)
#   3. x86 并发采集(collect_batch.sh)
#   4. converter -> relay 中转 -> node50 prep 写 genstep_k
#   5. 训练器 dataloader 解除阻塞, 进入第 k 轮
# 第 1 轮用预置 dump 自举
# ============================================================
set -u
ROUNDS=${ROUNDS:-2}
TASKS_COLLECT=${TASKS_COLLECT:-"arvo:1065 arvo:47101"}
AGENTS=${AGENTS:-2}
RELAY=119.8.234.170
X86=192.168.0.100
NODE50=192.168.0.50
DATA_DIR=/data/dataset/openhands_traj
TRAIN_LOG_GLOB="/data/z00666713/deepseek0715/logs/openhands_*.log"
CTR=cybergym-baseline-zhouzhi

log() { echo "[loop $(date +%H:%M:%S)] $*"; }

latest_log() { ssh -o StrictHostKeyChecking=no root@$NODE50 "ls -t $TRAIN_LOG_GLOB | head -1"; }

wait_step() {  # $1 = step number
  local L; L=$(latest_log)
  log "waiting for training/global_step:$1 in $(basename "$L")"
  ssh -o StrictHostKeyChecking=no root@$NODE50 "for i in \$(seq 1 720); do grep -q \"training/global_step:$1 \" $L 2>/dev/null && exit 0; sleep 10; done; exit 1" \
    || { log "TIMEOUT waiting step $1"; return 1; }
  log "step $1 done"
}

collect_and_dump() {  # $1 = round number
  local R=$1 TAG="loop_r${R}_$(date +%s)"
  log "collecting round $R: $TASKS_COLLECT x $AGENTS agents"
  ssh -o StrictHostKeyChecking=no root@$X86 "bash /data/collect_batch.sh \"$TASKS_COLLECT\" $AGENTS $TAG" || { log "collect failed r$R"; return 1; }
  ssh -o StrictHostKeyChecking=no root@$X86 "python3 /data/trajectory_converter.py --pg-password trajpass123 --workspace-glob '/data/cybergym_workspace/collect_$TAG/logs/*/args.json' --out $DATA_DIR/loop_$TAG.parquet" || return 1
  scp -o StrictHostKeyChecking=no root@$X86:$DATA_DIR/loop_$TAG.parquet /tmp/loop_$TAG.parquet || return 1
  scp -o StrictHostKeyChecking=no /tmp/loop_$TAG.parquet root@$NODE50:$DATA_DIR/loop_$TAG.parquet || return 1
  local NROWS GBS
  NROWS=$(ssh -o StrictHostKeyChecking=no root@$NODE50 "docker exec $CTR python3 -c \"import pandas as pd; print(len(pd.read_parquet('$DATA_DIR/loop_$TAG.parquet')))\"")
  GBS=$(( NROWS / 64 * 64 )); [ "$GBS" -lt 64 ] && GBS=64
  log "round $R: $NROWS turns -> gbs $GBS -> genstep_$R"
  # 逐轮 dump 尺寸必须与训练批(64)一致: trim/pad 由 prep 完成
  ssh -o StrictHostKeyChecking=no root@$NODE50 "docker exec $CTR python3 /tmp/prep_offline_dump.py --parquet $DATA_DIR/loop_$TAG.parquet --dump-dir $DATA_DIR/rollout_dump --exp-name cybergym_openhands_offline --gbs 64 --n 1 --prompt-length 12288 --response-length 1024 --truncate-prompt-len 12288 --drop-overlong --gen-step $R" || return 1
  log "round $R dump written (genstep_$R)"
}

# ---- main ----
log "orchestrator v2 start: ROUNDS=$ROUNDS"
for R in $(seq 2 "$ROUNDS"); do
  wait_step $((R-1)) || exit 1
  log "waiting engines healthy (post weight-sync)..."
  ssh -o StrictHostKeyChecking=no root@$X86 'for i in $(seq 1 60); do curl -s --max-time 3 http://192.168.0.100:9090/v1/models | grep -q data && exit 0; sleep 10; done; exit 1' \
    || { log "engines not healthy after 10min"; return 1; }
  log "engines healthy"
  collect_and_dump $R || exit 1
done
wait_step "$ROUNDS" && log "ALL $ROUNDS ROUNDS COMPLETE"
