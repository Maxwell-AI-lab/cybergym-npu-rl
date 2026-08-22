#!/bin/bash
# 补丁: 让 verl vLLM HTTP server 对外可访问
# 修改: server_address 改为 0.0.0.0 + 端口固定 9090
set -e
CNAME=cybergym-baseline-zhouzhi
FILE=/workspace-verl/verl/verl/workers/rollout/vllm_rollout/vllm_async_server.py
UTILS=/workspace-verl/verl/verl/workers/rollout/utils.py

for ip in 36 41 51 88 89 189 47 50 17 195 85 48; do
  echo "patching $ip..."
  (
    ssh -o StrictHostKeyChecking=no root@192.168.0.$ip "
      # 1. server_address 改为 0.0.0.0（L131）
      docker exec $CNAME sed -i 's/self._server_address = ray.util.get_node_ip_address().strip(\"\[\]\")/self._server_address = \"0.0.0.0\"/' $FILE

      # 2. 端口固定 9090（utils.py L63）
      docker exec $CNAME sed -i 's/port=int(os.environ.get(\"VLLM_SERVER_PORT\", \"0\"))/port=9090/' $UTILS

      # 3. 确保有 import os
      docker exec $CNAME grep -q 'import os' $UTILS || \
        docker exec $CNAME sed -i '1i import os' $UTILS

      # 验证
      echo -n '  address: '
      docker exec $CNAME grep '_server_address = ' $FILE | head -1
      echo -n '  port: '
      docker exec $CNAME grep 'port=' $UTILS | grep uvicorn | head -1

      # 清缓存
      docker exec $CNAME find /workspace-verl/verl -name __pycache__ -exec rm -rf {} + 2>/dev/null
    "
  ) &
done
wait
echo ALL-PATCHED
