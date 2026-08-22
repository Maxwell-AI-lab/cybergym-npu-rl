#!/bin/bash
# ============================================================
# T5-2 采集批: 并发拉起 OpenHands agents (x86 上运行)
#
# usage: collect_batch.sh "<task_id...>" <agents_per_task> <tag>
#   每个 (task, agent) 独立 session: <tag>-<task下划线>-a<i>
#   run 结束后 args.json 自带 (session, task, agent_id) 三元组,
#   converter 用 agent_id 精确 join poc.db —— 并发同任务不串
# 前置: trajproxy(:12300) 上游已指向集群 vLLM 服务(新权重)
# ============================================================
set -u
TASKS_STR=${1:?tasks}
AGENTS=${2:-4}
TAG=${3:-batch}
MAX_ITER=${MAX_ITER:-30}
TIMEOUT=${TIMEOUT:-1200}

cd /data/openhands-src
export PATH="$HOME/.local/bin:$PATH"
OUT=/data/cybergym_workspace/collect_${TAG}
mkdir -p "$OUT"

pids=()
for task in $TASKS_STR; do
  tname=$(echo "$task" | tr ':' '_')
  for i in $(seq 1 "$AGENTS"); do
    SESSION="${TAG}-${tname}-a${i}"
    LOG="$OUT/${SESSION}.log"
    echo "[$(date +%H:%M:%S)] launch $task agent$i session=$SESSION"
    poetry run python /data/cybergym-agent-examples/openhands/run.py \
      --model "openai//data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16" \
      --api_key "EMPTY" \
      --base_url "http://192.168.0.100:12300/s/${SESSION}/v1" \
      --max_output_tokens 2048 \
      --log_dir "$OUT/logs" --tmp_dir "$OUT/tmp" \
      --data_dir "/data/cybergym_src" \
      --task_id "$task" \
      --server "http://192.168.0.100:8666" \
      --timeout "$TIMEOUT" --max_iter "$MAX_ITER" \
      --difficulty level1 \
      > "$LOG" 2>&1 &
    pids+=($!)
  done
done

echo "waiting for ${#pids[@]} agents..."
fail=0
for p in "${pids[@]}"; do
  wait "$p" || fail=$((fail+1))
done
echo "[$(date +%H:%M:%S)] collect done: $(( ${#pids[@]} - fail ))/${#pids[@]} ok"
exit $(( fail > 0 ))
