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
n_resp_per_prompt=8                  # 8x8=64 必须整除训练NPU数(64)

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
    # Tool call 格式: deepseek 原生格式 (<｜tool▁calls▁begin｜>...)
    # 由 verl_integration/deepseek_tool_parser.py 注册（随工具模块加载时生效）
    # 备选: hermes / gpt-oss / qwen3_coder
    actor_rollout_ref.rollout.multi_turn.format="deepseek"
    # tokenization 校验模式
    actor_rollout_ref.rollout.multi_turn.tokenization_sanity_check_mode="strict"
)

# Agent loop 选择: verl 原生 tool_agent (状态机内置)
AGENT_LOOP_CONFIG=(
    actor_rollout_ref.rollout.agent.default_agent_loop="tool_agent"
    actor_rollout_ref.rollout.agent.num_workers=16
)

DATA_CONFIG=(
    data.train_files="${TRAIN_FILE}"
    data.val_files="${TEST_FILE}"
    data.prompt_key=prompt
    data.train_batch_size=${train_prompt_bsz}
    data.max_prompt_length=${max_prompt_length}
    data.max_response_length=${max_response_length}
    data.filter_overlong_prompts=False
    data.truncation="left"
)

MODEL_CONFIG=(
    actor_rollout_ref.model.path="${MODEL_PATH}"
    actor_rollout_ref.model.use_remove_padding=False
    actor_rollout_ref.model.mtp.enable_train=False
    actor_rollout_ref.model.mtp.enable=False
    actor_rollout_ref.actor.mindspeed.use_remove_padding=False
    actor_rollout_ref.model.trust_remote_code=True
)

ALGORITHM_CONFIG=(
    algorithm.adv_estimator=${adv_estimator}
    algorithm.use_kl_in_reward=${use_kl_in_reward}
    algorithm.kl_ctrl.kl_coef=${kl_coef}
)

ACTOR_CONFIG=(
    actor_rollout_ref.actor.use_torch_compile=False
    actor_rollout_ref.actor.use_dynamic_bsz=${use_dynamic_bsz}
    actor_rollout_ref.actor.use_kl_loss=${use_kl_loss}
    actor_rollout_ref.actor.kl_loss_coef=${kl_loss_coef}
    actor_rollout_ref.actor.entropy_coeff=0
    actor_rollout_ref.actor.ppo_epochs=1
    actor_rollout_ref.actor.ppo_micro_batch_size_per_gpu=1
    actor_rollout_ref.actor.ppo_max_token_len_per_gpu=${actor_ppo_max_token_len}
    actor_rollout_ref.actor.ppo_mini_batch_size=${train_prompt_mini_bsz}
    actor_rollout_ref.actor.optim.lr=1e-6
    actor_rollout_ref.actor.mindspeed.tensor_model_parallel_size=${train_tp}
    actor_rollout_ref.actor.mindspeed.pipeline_model_parallel_size=${train_pp}
    actor_rollout_ref.actor.mindspeed.context_parallel_size=${train_cp}
    actor_rollout_ref.actor.mindspeed.expert_model_parallel_size=${train_ep}
    actor_rollout_ref.actor.mindspeed.expert_tensor_parallel_size=${train_etp}
    actor_rollout_ref.actor.mindspeed.param_offload=${all_offload}
    actor_rollout_ref.actor.mindspeed.optimizer_offload=False
    actor_rollout_ref.actor.mindspeed.grad_offload=${all_offload}
    actor_rollout_ref.actor.mindspeed.use_dist_checkpointing=False
    actor_rollout_ref.actor.mindspeed.use_mbridge=True
    +actor_rollout_ref.actor.optim.override_optimizer_config.optimizer_cpu_offload=True
    +actor_rollout_ref.actor.optim.override_optimizer_config.use_precision_aware_optimizer=True
    +actor_rollout_ref.actor.optim.override_optimizer_config.optimizer_offload_fraction=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.swap_optimizer=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.enable_dsa_indexer=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.index_n_heads=64
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.index_head_dim=128
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.index_topk=512
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.hc_mult=4
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.enable_mhc=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.kv_compress=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.norm_eps=1e-6
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.multi_latent_attention=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.qk_pos_emb_head_dim=64
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.qk_head_dim=512
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.q_lora_rank=1024
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.o_lora_rank=1024
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.kv_lora_rank=512
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.v_head_dim=128
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.qk_layernorm=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.mla_fa_without_pad=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_g2_attention=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.o_groups=8
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.g2_window_size=128
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_head_dim=64
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.original_seq_len=65536
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_factor=16
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.compress_rope_theta=160000.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.max_batch_size=4
        +actor_rollout_ref.actor.mindspeed.llm_kwargs.compress_ratios="[0,0,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4,128,4]"
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_grouped_gemm=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_permutation_async_comm=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_token_dispatcher_type=alltoall
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_layer_freq=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.first_k_dense_replace=-1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.num_experts=256
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_topk=6
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_ffn_hidden_size=2048
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.ffn_hidden_size=2048
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_load_balancing_type=none
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_group_topk=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_num_groups=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_topk_scaling_factor=1.5
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.seq_aux=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_aux_loss_coeff=0.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_score_function=sqrtsoftplus
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_enable_expert_bias=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_shared_expert_intermediate_size=2048
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.fix_router=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_router_dtype=fp32
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.n_hash_layers=3
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.mtp_num_layers=0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.mtp_loss_scaling_factor=0.3
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.mtp_mem_efficient_logits=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.recompute_granularity=full
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.recompute_method=uniform
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.recompute_num_layers=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.beta_fast=32
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.beta_slow=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_scaling_factor=16
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_scaling_mscale=1.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_scaling_mscale_all_dim=1.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_scaling_original_max_position_embeddings=65536
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_theta=10000.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rope_scaling_type=yarn
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.transformer_impl=local
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.spec="[\"mindspeed_llm.tasks.models.spec.deepseek4_spec\", \"layer_spec\"]"
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.manual_gc=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.manual_gc_interval=50
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_shared_storage=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_distributed_optimizer=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_flash_attn=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_mcore_models=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.num_layers=43
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.accumulate_allreduce_grads_in_fp32=False \
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.main_grads_dtype=bf16 \
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.num_layer_list="\"21,22\""

    +actor_rollout_ref.actor.mindspeed.llm_kwargs.hidden_size=4096
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.num_attention_heads=64
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.tokenizer_type=PretrainedFromHF
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.tokenizer_name_or_path=$MODEL_PATH
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.seq_length=$actor_ppo_max_token_len
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.max_position_embeddings=1048576
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.micro_batch_size=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.global_batch_size=128
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.make_vocab_size_divisible_by=1
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.lr=1e-6
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.train_iters=200
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.lr_decay_style=constant
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.untie_embeddings_and_output_weights=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.disable_bias_linear=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.add_bias_linear=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.attention_dropout=0.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.init_method_std=0.02
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.hidden_dropout=0.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.position_embedding_type=g2
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.normalization=RMSNorm
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_fused_rotary_pos_emb=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_rotary_position_embeddings=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_fused_swiglu=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_fused_rmsnorm=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.swiglu=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.swiglu_limit=10.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_masked_softmax_fusion=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.attention_softmax_in_fp32=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.min_lr=1e-6
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.weight_decay=1e-2
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.clip_grad=1.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.adam_beta1=0.9
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.adam_beta2=0.999
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.initial_loss_scale=65536
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.vocab_size=129280
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.padded_vocab_size=129280
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.rotary_base=10000
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.norm_epsilon=1e-6
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_load_optim=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_load_rng=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.bf16=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.distributed_timeout_minutes=120
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_gradient_accumulation_fusion=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.gradient_accumulation_fusion=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_save_optim=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_save_rng=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.context_parallel_algo=ulysses_cp_algo
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.masked_softmax_fusion=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.moe_shared_expert_overlap=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.indexer_loss_coeff=0.0
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_triton_sfa=True
    ++actor_rollout_ref.actor.mindspeed.llm_kwargs.use_triton_sfa=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_triton_mhc=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_triton_sinkhorn=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_triton_rmsnorm_without_weight=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.no_pad_to_seq_lengths=True
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_fused_lightning_indexer=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_fused_lightning_indexer_loss=False
    +actor_rollout_ref.actor.mindspeed.llm_kwargs.use_sparse_flash_attn=True
)

REF_CONFIG=(
    actor_rollout_ref.ref.use_torch_compile=False
    actor_rollout_ref.ref.log_prob_micro_batch_size_per_gpu=1
    actor_rollout_ref.ref.log_prob_use_dynamic_bsz=${use_dynamic_bsz}
    actor_rollout_ref.ref.log_prob_max_token_len_per_gpu=${infer_ppo_max_token_len}
    actor_rollout_ref.ref.mindspeed.tensor_model_parallel_size=${train_tp}
    actor_rollout_ref.ref.mindspeed.pipeline_model_parallel_size=${train_pp}
    actor_rollout_ref.ref.mindspeed.context_parallel_size=${train_cp}
    actor_rollout_ref.ref.mindspeed.expert_model_parallel_size=${train_ep}
    actor_rollout_ref.ref.mindspeed.expert_tensor_parallel_size=${train_etp}
    actor_rollout_ref.ref.mindspeed.param_offload=${all_offload}
    actor_rollout_ref.ref.mindspeed.use_dist_checkpointing=False
    actor_rollout_ref.ref.mindspeed.use_mbridge=True
)

ROLLOUT_CONFIG=(
    actor_rollout_ref.rollout.max_num_seqs=16
    actor_rollout_ref.rollout.nnodes=4
    actor_rollout_ref.rollout.n_gpus_per_node=8
    actor_rollout_ref.rollout.checkpoint_engine.backend=hccl
    actor_rollout_ref.rollout.checkpoint_engine.custom_backend_module=verl.checkpoint_engine.hccl_checkpoint_engine


    +actor_rollout_ref.rollout.engine_kwargs.vllm.enable_sleep_mode=False
    +actor_rollout_ref.rollout.engine_kwargs.vllm.enable_auto_tool_choice=False
    actor_rollout_ref.rollout.max_model_len=${max_model_len}
    actor_rollout_ref.rollout.calculate_log_probs=True
    actor_rollout_ref.rollout.name=vllm
    actor_rollout_ref.rollout.load_format="safetensors"
    actor_rollout_ref.rollout.n=${n_resp_per_prompt}
    actor_rollout_ref.rollout.top_p=1.0
    actor_rollout_ref.rollout.top_k=-1
    actor_rollout_ref.rollout.top_k=50
    actor_rollout_ref.rollout.temperature=1.0
    actor_rollout_ref.rollout.log_prob_micro_batch_size_per_gpu=1
    actor_rollout_ref.rollout.log_prob_use_dynamic_bsz=${use_dynamic_bsz}
    actor_rollout_ref.rollout.log_prob_max_token_len_per_gpu=${infer_ppo_max_token_len}
    actor_rollout_ref.rollout.gpu_memory_utilization=${gpu_memory_utilization}
    actor_rollout_ref.rollout.tensor_model_parallel_size=${gen_tp}
    actor_rollout_ref.rollout.data_parallel_size=${gen_dp}
    actor_rollout_ref.rollout.expert_parallel_size=${gen_ep}
    actor_rollout_ref.rollout.enforce_eager=True
    "+actor_rollout_ref.rollout.engine_kwargs.vllm.speculative_config={method: \"dspark\", num_speculative_tokens:5}"
    +actor_rollout_ref.rollout.engine_kwargs.vllm.compilation_config.cudagraph_mode="FULL_DECODE_ONLY"
    "+actor_rollout_ref.rollout.engine_kwargs.vllm.additional_config={enable_dsa_cp: false, enable_flashcomm1:false, enable_reduce_sample:false}"
    +actor_rollout_ref.rollout.engine_kwargs.vllm.async_scheduling=False
    actor_rollout_ref.rollout.free_cache_engine=False
)

REWARD_CONFIG=(
    reward.custom_reward_function.path="${REWARD_FN_PATH}"
    reward.custom_reward_function.name="compute_score"
)

TRAINER_CONFIG=(
    trainer.logger="[\"console\"]"
    trainer.project_name="${project_name}"
    trainer.experiment_name="${exp_name}"
    trainer.nnodes="${NNODES}"
    trainer.n_gpus_per_node="${NPUS_PER_NODE}"
    trainer.device="npu"
    trainer.total_epochs=1
    trainer.val_before_train=False
    trainer.test_freq=-1
    trainer.save_freq=0
    trainer.default_local_dir="${CKPTS_DIR}"
    trainer.use_legacy_worker_impl=disable
)

PYTHONUNBUFFERED=1 python3 -c "import sys; sys.path.insert(0,'/data/z00666713/deepseek0715'); import register_dsv4" && PYTHONUNBUFFERED=1 python3 -m verl.trainer.main_ppo \
    --config-name="ppo_trainer.yaml" \
    model_engine=mindspeed \
    "${DATA_CONFIG[@]}" \
    "${MODEL_CONFIG[@]}" \
    "${ACTOR_CONFIG[@]}" \
    "${REF_CONFIG[@]}" \
    "${ROLLOUT_CONFIG[@]}" \
    "${ALGORITHM_CONFIG[@]}" \
    "${REWARD_CONFIG[@]}" \
    "${MULTI_TURN_CONFIG[@]}" \
    "${AGENT_LOOP_CONFIG[@]}" \
    "${TRAINER_CONFIG[@]}" \
    "$@" 2>&1 | stdbuf -oL tee /data/z00666713/deepseek0715/logs/cybergym_mt_$(date +%Y%m%d_%H%M%S).log