#!/bin/bin/bash
# 补丁: 让 verl vLLM HTTP server 用环境变量指定的固定端口（默认 9090）
# 原因: port=0 随机分配 → 外部（trajproxy/OpenHands）无法预知端口
set -e
HEAD=36
TRAIN_NODES="41 51 88 89 189 47 50"
ROLLOUT_NODES="17 195 85 48"
ALL_NODES="$HEAD $TRAIN_NODES $ROLLOUT_NODES"
CNAME=cybergym-baseline-zhouzhi
FILE=/workspace-verl/verl/verl/workers/rollout/utils.py

# 补丁内容: port=0 → port=int(os.environ.get("VLLM_SERVER_PORT", "0"))
# 如果 VLLM_SERVER_PORT 没设置，行为不变（随机端口）
PATCH='    config = uvicorn.Config(app, host=server_address, port=int(os.environ.get("VLLM_SERVER_PORT", "0")), log_level="warning")'

for ip in $ALL_NODES; do
  echo "patching node $ip..."
  ssh -o StrictHostKeyChecking=no root@192.168.0.$ip "
    # 检查是否已打补丁
    if docker exec $CNAME grep -q 'VLLM_SERVER_PORT' $FILE 2>/dev/null; then
      echo '  already patched'
      exit 0
    fi
    # 备份
    docker exec $CNAME cp $FILE $FILE.bak
    # 替换 port=0
    docker exec $CNAME sed -i 's/port=0, log_level/port=int(os.environ.get(\"VLLM_SERVER_PORT\", \"0\")), log_level/' $FILE
    # 验证
    docker exec $CNAME grep -n 'VLLM_SERVER_PORT' $FILE | head -1
    # 清缓存
    docker exec $CNAME find /workspace-verl/verl -name __pycache__ -exec rm -rf {} + 2>/dev/null
  " &
done
wait
echo "ALL PATCHED"
