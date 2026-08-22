#!/bin/bash
# 4-agent concurrent E2E: test parallelism + generate training trajectories
# Each agent runs in its own container with isolated trial_id
set -e

TASKS=("arvo:1065" "arvo:3938" "arvo:47101" "oss-fuzz:370689421")
BASE_PORT=9100

cd /data/openhands-src
export PATH="$HOME/.local/bin:$PATH"
OUT_DIR="/data/cybergym_workspace/e2e_concurrent"
mkdir -p $OUT_DIR

echo "=== Starting 4 concurrent agents ==="
date

PIDS=()
for i in "${!TASKS[@]}"; do
    TASK="${TASKS[$i]}"
    TRIAL_ID="concurrent-e2e-task${i}-$(date +%s)"
    LOG="$OUT_DIR/agent_${i}_${TASK//[:\/]/_}.log"
    
    echo "[Agent $i] Task: $TASK → $LOG"
    
    poetry run python /data/cybergym-agent-examples/openhands/run.py \
        --model "openai//data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16" \
        --api_key "EMPTY" \
        --base_url "http://192.168.0.100:12300/s/${TRIAL_ID}/v1" \
        --max_output_tokens 2048 \
        --log_dir "$OUT_DIR/logs" \
        --tmp_dir "$OUT_DIR/tmp" \
        --data_dir "/data/cybergym_src" \
        --task_id "$TASK" \
        --server "http://192.168.0.100:8666" \
        --timeout 1200 \
        --max_iter 20 \
        --difficulty level1 \
        > "$LOG" 2>&1 &
    
    PIDS+=($!)
    echo "  PID: $PID"
    sleep 2  # stagger starts
done

echo ""
echo "=== Waiting for all agents ==="
for pid in "${PIDS[@]}"; do
    wait $pid
    echo "  Agent PID $pid completed (exit: $?)"
done

echo ""
echo "=== Results ==="
date
echo "Trajectories captured:"
docker exec traj_db psql -U traj -d traj_proxy -c \
    "SELECT session_id, COUNT(*) as turns, SUM(prompt_tokens) as total_tokens 
     FROM request_metadata WHERE session_id LIKE 'concurrent%' GROUP BY session_id;"

echo "CyberGym submissions:"
grep "submit-vul done" /data/cybergym/server.out | tail -10

echo ""
echo "CONCURRENT-E2E-DONE"
