# CyberGym + DeepSeek V4 Flash RL 后训练 工作总结

**日期**: 2026-08-21
**状态**: 单轮训练链路跑通 ✅，多轮 Agent 集成进行中 🔄

---

## 1. 项目目标

在 12 节点 Ascend 910B 集群上，使用 verl GRPO 框架对 DeepSeek V4 Flash 进行 CyberGym RL 后训练，目标是让模型学会：
1. 分析软件漏洞（CyberGym 平台，arvo 任务）
2. 生成触发 crash 的 PoC 代码（reward +1.0）
3. 生成能让 patch 版本通过的 PoC（reward 额外 +0.5）
4. 通过多轮工具交互（read_file / submit_poc / execute_code）迭代优化

---

## 2. 硬件 & 集群架构

| 角色 | 节点 | IP | 用途 |
|------|------|----|------|
| Head | 36 | 192.168.0.36 | Ray head + 8 训练 NPU |
| Train | 41,51,88,89,189,47,50 | - | 7 节点 × 8 NPU = 56 训练 NPU |
| Rollout | 17,195,85,48 | - | 4 节点 × 8 NPU = 32 推理 NPU (vLLM) |
| x86 Server | 192.168.0.100 | 192.168.0.100 | CyberGym 服务 + opencode Agent |

- **容器**: `cybergym-baseline-zhouzhi`，12 台 910B 均部署同一镜像
- **网络**: 训练集群内可直连，x86 需通过 SSH 隧道或公网 IP 访问

---

## 3. 关键修复记录（已解决）

### 3.1 权重同步 crash（copy_d2d_baseformat_opapi，w2 shape 不匹配）

**现象**: v2 训练时 crash，WL-DBG 显示 `isk=True model.layers.0.mlp.experts.routed_experts.w13_weight eid=88 shard=w1 w=(4096, 2048)` — 参数已在 kernel layout（kernel 期望的格式）但 shard_dim 仍按 vllm layout 计算。

**根因**: vllm-ascend 的 `PWAL`（process_weights_after_loading）会**转置** MoE 权重到 kernel layout。HCCL 同步时，训练端（vllm layout）与 rollout 端（kernel layout）参数 shape 不一致导致 copy_d2d 报错。

**修复 v3-final**（`/workspace-verl/vllm-ascend/vllm_ascend/models/deepseek_v4.py`）：
```python
# 检测 kernel MoE 布局
_is_kernel_moe = name and "expert" in name and "w" in name
if _is_kernel_moe and is_kernel:
    # 把参数 revert 回 vllm layout 再加载
    ...

```

**教训**: 最初只改了 head 节点，其他 11 个节点没打补丁，导致 rollout worker 加载失败。修复分发到全部 12 节点后才稳定。

### 3.2 master_param KeyError（distrib_optimizer.py:836）

**现象**: v8 crash `KeyError: 'master_param'`，CPU offload 后的 optimizer state 不含 master_param。

**根因**: `tensors["param"] = tensors.pop("master_param")` 写死假设存在 master_param，但 `use_precision_aware_optimizer=True` + `optimizer_cpu_offload=True` 组合下 master_param 不存在。

**修复**（`/workspace-verl/verl/megatron/core/optimizer/distrib_optimizer.py`）：
```python
if "master_param" in tensors:
    tensors["param"] = tensors.pop("master_param")
else:
    tensors["param"] = sharded_model_param  # fallback
```

### 3.3 OOM（v9/v10，HBM 56.45GB）

**现象**: `use_precision_aware_optimizer=False` 导致 910B HBM 爆满。

**结论**: 必须保持 `use_precision_aware_optimizer=True`（节省显存），同时配合 §3.2 的 master_param fallback。

### 3.4 Checkpoint shape 不匹配（v11）

**现象**: `CheckpointsException: shape mismatch` 出现在保存 checkpoint 时。

**修复**: `save_freq=0`（禁用 checkpoint 保存，训练阶段足够验证）。

### 3.5 脚本分发到 12 节点

**现象**: 早期只在 head 节点 docker cp 了修复脚本，其他 11 个节点仍是原版。

**修复**: scp 脚本到每个节点 → `docker cp` 进入容器 → 删除 `__pycache__` → 验证所有节点的 fix count = 1。

---

## 4. 单轮训练验证（已完成 ✅）

**v12 run（step:1 完成，零错误）**：
- main_ppo 进程正常退出
- reward 函数正确调用（[REWARD-DBG] 打印轨迹前 300 字符）
- 轨迹质量正常：无乱码、能进行漏洞分析、生成合理的 Python PoC 代码

---

## 5. 当前进行中的工作

### 5.1 opencode Agent 集成 🔄

**目标**: 让 opencode 作为完整 Agent，支持多轮工具交互（read_file / submit_poc / execute_code），在训练时提供真实的多轮轨迹。

**架构设计**:
```
训练集群 (910B)                          x86 容器 (192.168.0.100)
┌────────────────┐                    ┌─────────────────────┐
│ vLLM (rollout) │ ──HTTP──>          │ opencode serve      │
│                │                    │ :8099               │
│ tool_agent_loop│                    │ (deepseek-v4-flash) │
│  (verl)        │ <──HTTP──          │                     │
└────────────────┘                    └────────┬────────────┘
                                               │
                                         调用工具（本地）
```

**当前进度**:
- ✅ x86 服务器 Docker 容器已启动（`opencode-agent`，ubuntu:24.04，host network，挂载 /data）
- ⏳ opencode 安装脚本进行中（apt-get + curl install，被中断）
- ⏸ Phase 1b: 配置 deepseek provider（**需要 DEEPSEEK_API_KEY**）
- ⏸ Phase 2: 编写 `opencode_agent_loop.py`（verl @register 注册）
- ⏸ Phase 3: reward 适配多轮轨迹（PoC 提取 + CyberGym 验证）
- ⏸ Phase 4: 训练配置 + 12 节点同步
- ⏸ Phase 5: 最小链路验证 → 完整训练

### 5.2 DEEPSEEK_API_KEY 依赖

opencode 需要 LLM 来驱动 Agent 推理。当前情况：
- 训练集群的 vLLM 引擎无法从 x86 服务器访问（网络隔离）
- x86 可访问 `api.deepseek.com`
- 因此 opencode 使用外部 `deepseek-v4-flash` 作为 LLM provider
- **需要用户提供 DEEPSEEK_API_KEY**（`sk-...` 格式，从 https://platform.deepseek.com 获取）
- 费用极低：一轮交互约 3 万 token，约 $0.00013

---

## 6. 代码文件清单

### 已实现（本地）

| 文件 | 说明 |
|------|------|
| `verl_integration/cybergym_reward.py` | 自定义 reward 函数，HTTP 调 CyberGym submit-vul/submit-fix，异步+重试 |
| `verl_integration/cybergym_tools.py` | 3 个纯 Python 工具函数 + TOOL_SCHEMAS（未接入 BaseTool） |
| `verl_integration/system_prompt.py` | 安全研究员 system prompt，支持 level0-3 难度 |
| `configs/train_cybergym_v2.sh` | 训练启动脚本（已修复 save_freq=0, use_precision_aware_optimizer=True） |
| `deploy/setup_x86.sh` | x86 服务器部署脚本 |
| `data/prepare_data.py` | CyberGym 任务 → verl parquet 转换 |

### 远端 12 节点（已应用修复）

| 文件 | 修复内容 |
|------|---------|
| `/workspace-verl/vllm-ascend/vllm_ascend/models/deepseek_v4.py` | kernel MoE 布局检测 + 参数 revert |
| `/workspace-verl/verl/megatron/core/optimizer/distrib_optimizer.py` | master_param fallback |

---

## 7. 关键技术决策

1. **GRPO 而非 PPO**: 单轮生成 + group comparison，不需要 baseline critic，资源更省
2. **DSpark speculative decoding**（num_speculative_tokens=5）: 加速 rollout 阶段推理
3. **vllm-ascend**: 910B 专用 vLLM 后端，带 MoE 权重转置（kernel layout）
4. **混合精度 optimizer**: `use_precision_aware_optimizer=True` 节省显存，配合 CPU offload
5. **Ray placement groups**: 96 NPUs = 8 train + 4 rollout，分布式 HCCL 权重同步
6. **工具函数设计**: 纯 Python（无 BaseTool），便于本地测试和迭代

---

## 8. 下一步行动

1. **提供 DEEPSEEK_API_KEY** → 完成 opencode 安装和 serve 配置
2. **编写 `opencode_agent_loop.py`** → 注册 `@register("opencode_agent")`，实现 session 创建、消息发送、轨迹检索
3. **reward 适配** → 从多轮对话中提取最终 PoC，调 CyberGym 验证
4. **训练配置** → `agent.name=opencode_agent` + multi_turn tools 配置
5. **12 节点同步** → 分发新文件，清理 pycache
6. **最小链路验证** → 单任务单 batch 跑通，检查轨迹质量
7. **完整训练** → 10 任务 × n=4 rollout，监控 reward 曲线
