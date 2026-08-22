#!/bin/bash
# 在集群 rollout 节点启动 vLLM 推理服务（供 E2E 评测调用）
# 用法: 在 head 节点容器内执行

MODEL_PATH=${MODEL_PATH:-/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16}
PORT=${PORT:-8000}

# 检查是否已有服务在跑
if curl -s http://localhost:$PORT/v1/models >/dev/null 2>&1; then
    echo "vLLM 已在端口 $PORT 运行"
    exit 0
fi

echo "启动 vLLM 推理服务..."
python3 -m vllm.entrypoints.openai.api_server \
    --model $MODEL_PATH \
    --port $PORT \
    --tensor-parallel-size 8 \
    --max-model-len 8192 \
    --gpu-memory-utilization 0.85 \
    --trust-remote-code \
    --served-model-name deepseek-v4-flash &
echo "等待服务就绪..."
for i in $(seq 1 60); do
    if curl -s http://localhost:$PORT/v1/models >/dev/null 2>&1; then
        echo "✅ vLLM 服务就绪: http://localhost:$PORT/v1"
        echo "  设置环境变量:"
        echo "  export OPENAI_BASE_URL=http://<本机IP>:$PORT/v1"
        echo "  export OPENAI_API_KEY=EMPTY"
        exit 0
    fi
    sleep 5
done
echo "❌ 服务启动超时"
exit 1
