export PYTHONUNBUFFERED=1
#!/bin/bash
# ============================================================
# CyberGym Multi-Turn Agent Training Script
#
# Based on train_cybergym_v2.sh (single-turn GRPO), upgraded to
# multi-turn tool_agent_loop with three CyberGym tools:
#   - read_file: Read task files (description.txt, etc.)
#   - submit_poc: Submit PoC to CyberGym server
#   - execute_code: Execute Python code in sandbox
#
# Key changes from single-turn:
#   1. agent.default_agent_loop = "tool_agent"
#   2. multi_turn.* config enabled
#   3. max_response_length increased (multi-turn needs more tokens)
#   4. max_model_len increased (prompt + all turns + tool responses)
#   5. Tool config path points to tool_config.yaml
#
# Prerequisites:
#   - Single-turn v12 verified working
#   - tool_config.yaml deployed to all 12 nodes
#   - cybergym_tools_verl.py deployed to all 12 nodes
#   - CyberGym Server running on x86 (192.168.0.100:8666)
# ============================================================
export ASCEND_LAUNCH_BLOCKING=0
export PYTHONFAULTHANDLER=1
export PYTHONPATH=/workspace-verl:/workspace-verl/verl:/vllm-workspace/vllm-ascend:$PYTHONPATH
export PYTHONPATH=/workspace-verl:/workspace-verl/verl:/vllm-workspace:/vllm-workspace/vllm-ascend:$PYTHONPATH
export PATH=/usr/local/python3.12.13/bin:$PATH
export HCCL_BUFFSIZE=200
export VLLM_USE_V1=1
export VLLM_DSA_INDEXER_MODE=int8
export VERL_ROLLOUT_BUNDLE_CUSTOM_RESOURCES='{"rollout_node": 1e-4}'
export HCCL_DEBUG=1 HCCL_DEBUG_FILE=/tmp/hccl_debug_$(hostname -I | awk "{print $1}").log
export HYDRA_FULL_ERROR=1
export PYTHONPATH=/usr/local/Ascend/cann-9.0.0/python/site-packages:/usr/local/Ascend/ascend-toolkit/latest/python/site-packages:/workspace-verl/vllm:/workspace-verl/vllm-ascend:/workspace-verl/verl:/data/z00666713/deepseek0715

# --- CyberGym Server ---
export CYBERGYM_SERVER_URL="${CYBERGYM_SERVER_URL:-http://192.168.0.100:8666}"
export CYBERGYM_API_KEY="${CYBERGYM_API_KEY:-cybergym-030a0cd7-5908-4862-8ab9-91f2bfc7b56d}"
export CYBERGYM_SUBMIT_TIMEOUT=120

# --- Tool config path (must be absolute, same on all 12 nodes) ---
TOOL_CONFIG_PATH="/data/z00666713/deepseek0715/cybergym_integration/verl_integration/tool_config.yaml"

project_name="DeepSeek-V4-Flash"
exp_name="DeepSeek-V4-Flash-CyberGym-MultiTurn"

# ---- 硬件 (适配910B: 8卡/节点) ----
NNODES=${NNODES:-8}
NPUS_PER_NODE=${NPUS_PER_NODE:-8}

# ---- 路径 (CyberGym 数据集) ----
MODEL_PATH=/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16
RAY_DATA_HOME=${RAY_DATA_HOME:-"${HOME}/verl"}
CKPTS_DIR=/data/z00666713/deepseek0715/checkpoints_cybergym
TRAIN_FILE=/data/dataset/cybergym/train.parquet
TEST_FILE=/data/dataset/cybergym/test.parquet

# ---- 数据长度 (多轮模式需要更多空间) ----
max_prompt_length=$((1024 * 4))     # 4K prompt (system + task description)
max_response_length=4096             # 多轮: LLM生成 + 工具调用 + 工具响应

# ---- Batch ----
train_prompt_bsz=8
train_prompt_mini_bsz=8
n_resp_per_prompt=4                  # 多轮更贵，降低采样数

# ---- 算法 ----
adv_estimator=grpo
use_kl_in_reward=False
kl_coef=0.0
use_kl_loss=False
kl_loss_coef=0.001

# ---- 显存管理 ----
all_offload=True
use_dynamic_bsz=False
actor_ppo_max_token_len=$(((max_prompt_length + max_response_length)))
infer_ppo_max_token_len=$(((max_prompt_length + max_response_length)))

# ---- 并行策略 (不变) ----
train_tp=4
train_ep=32
train_etp=1
train_pp=2
train_cp=1

# ---- 推理并行 (不变) ----
gen_tp=8
gen_dp=4
gen_ep=32
gpu_memory_utilization=0.72
max_model_len=$((max_prompt_length + max_response_length))
max_num_batched_tokens=0

# ---- Reward function path ----
REWARD_FN_PATH="/data/z00666713/deepseek0715/cybergym_integration/verl_integration/cybergym_reward.py"

# ============================================================
# Multi-Turn Agent 配置 (新增)
# ============================================================
MULTI_TURN_CONFIG=(
    # 启用多轮 agent loop
    actor_rollout_ref.rollout.multi_turn.enable=True
    # 工具配置文件路径
    actor_rollout_ref.rollout.multi_turn.tool_config_path="${TOOL_CONFIG_PATH}"
    # 最大交互轮次 (assistant + user 各算一轮)
    actor_rollout_ref.rollout.multi_turn.max_assistant_turns=8
    actor_rollout_ref.rollout.multi_turn.max_user_turns=8
    # 每轮最大并行工具调用数
    actor_rollout_ref.rollout.multi_turn.max_parallel_calls=1
    # 工具响应最大字符数 (防止超长源码撑爆上下文)
    actor_rollout_ref.rollout.multi_turn.max_tool_response_length=2048
    # 截断方向: 中间截断保留头尾
    actor_rollout_ref.rollout.multi_turn.tool_response_truncate_side="middle"
    # Tool call 格式: hermes (<tool_call>JSON