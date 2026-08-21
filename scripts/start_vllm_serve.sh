#!/bin/bash
# Start vLLM serve for DeepSeek V4 Flash baseline evaluation
# Run inside container: bash /data/z00666713/deepseek0715/cybergym_integration/scripts/start_vllm_serve.sh

source /usr/local/Ascend/ascend-toolkit/set_env.sh 2>/dev/null || true
source /usr/local/Ascend/nnal/atb/set_env.sh 2>/dev/null || true

export VLLM_USE_V1=1
export VLLM_DSA_INDEXER_MODE=int8
export HCCL_BUFFSIZE=1024
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True

MODEL_PATH=/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16
LOG_FILE=/data/z00666713/deepseek0715/logs/vllm_serve.log
mkdir -p /data/z00666713/deepseek0715/logs

echo "Starting vLLM serve on $(date)..."
echo "Model: $MODEL_PATH"
echo "Log: $LOG_FILE"

python3 -m vllm.entrypoints.openai.api_server \
  --model "$MODEL_PATH" \
  --tensor-parallel-size 8 \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.72 \
  --port 8000 \
  --trust-remote-code \
  --enforce-eager \
  --speculative-config '{"method": "dspark", "num_speculative_tokens": 5}' \
  2>&1 | tee "$LOG_FILE"
