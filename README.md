# CyberGym NPU RL

**CyberGym 漏洞分析任务的 RL 后训练**：在 12 节点昇腾 Ascend 910B 集群上，用 [verl](https://github.com/volcengine/verl) GRPO 对 DeepSeek V4 Flash 做多轮工具交互强化学习，模型自主调用工具（读任务文件 / 执行代码 / 提交 PoC），由 [CyberGym](https://github.com/sunblaze-ucb/cybergym)（UC Berkeley，ICLR 2026）官方验证服务判定 PoC 是否触发漏洞 crash，形成数据 → 多轮推理 → 真实 reward → 策略更新的完整闭环。

## 架构

```
训练集群 (12× Ascend 910B, aarch64)                x86 服务器 (192.168.0.100)
┌────────────────────────────────────┐           ┌──────────────────────────┐
│ 8 Train 节点 (Megatron GRPO)       │           │ CyberGym Server (:8666)  │
│   │ HCCL 权重同步                   │           │  · FastAPI 官方验证服务   │
│   ▼                                │           │  · PoC hash 去重 (SQLite) │
│ 4 Rollout 节点 (vLLM + tool loop)  │──HTTP───► │  · vul/fix 双容器验证     │
│   · 多轮 tool_agent_loop 状态机     │           │    network=none 隔离      │
│   · LLM 生成 token → mask=1        │           │  · checksum 防作弊        │
│   · 工具返回 token → mask=0        │           └──────────────────────────┘
│   · 工具: read_file/execute_code/  │
│            submit_poc (原生异步)    │
└────────────────────────────────────┘
```

**训练语义**：模型自己生成全部轨迹 token（何时调工具、怎么写 PoC），reward 直接回馈给同一模型——不依赖外部黑盒 Agent（opencode/trajproxy 均不需要）。

## 硬件

| 角色 | 节点 (192.168.0.x) | 规格 |
|------|-------------------|------|
| Ray Head + Train | .36 | 8× 910B |
| Train | .41 .51 .88 .89 .189 .47 .50 | 7×8 = 56 NPU |
| Rollout (vLLM) | .17 .195 .85 .48 | 4×8 = 32 NPU |
| CyberGym Server | .100 | x86, 32C/64GB, 500GB |

并行策略：Train TP=4/PP=2/EP=32；Rollout TP=8/DP=4/EP=32 + DSpark 投机解码（num_speculative_tokens=5）。

## 仓库结构

```
├── PLAN.md                    # 总体方案（含源码级接口分析）
├── PHASE1_PLAN.md             # Phase 1：多轮训练跑通方案（风险/步骤/验收标准）
├── MULTITURN_PLAN.md          # 多轮技术细节（状态机/上下文预算/部署清单）
├── WORK_SUMMARY.md            # 工作进展总结
├── data/
│   ├── prepare_data.py        # 任务 → verl parquet（含 Task ID 标记）
│   └── task_list.json         # 10 个训练任务
├── verl_integration/
│   ├── cybergym_tools_verl.py # 3 个 BaseTool（原生 async）
│   ├── tool_config.yaml       # 工具注册配置（OmegaConf）
│   ├── cybergym_reward.py     # reward 函数（单轮/多轮通用）
│   ├── cybergym_tools.py      # 工具纯函数实现（同步版，测试用）
│   └── system_prompt.py       # 安全研究员 prompt（含 hermes tool-call 格式）
├── configs/
│   ├── train_cybergym.sh      # 单轮训练脚本（v12 已验证）
│   ├── train_cybergym_v2.sh   # 单轮稳定版（save_freq=0 等修复）
│   └── train_cybergym_multiturn.sh  # 多轮训练脚本
├── deploy/
│   ├── setup_x86.sh           # x86 CyberGym Server 部署
│   └── setup_tunnel.sh        # SSH 隧道（备用）
└── scripts/                   # 测试/评估/运维脚本
```

## 快速开始

### 1. x86 部署 CyberGym Server

```bash
# x86 服务器上（Ubuntu 24.04, Docker 已装）
bash deploy/setup_x86.sh
export CYBERGYM_RATE_LIMIT_MAX_REQUESTS=200   # 训练并发需要调高
python3 -m cybergym.server --host 0.0.0.0 --port 8666
```

10 个任务的 vul/fix Docker 镜像（`n132/arvo:*`、`cybergym/oss-fuzz:*`）需预先 pull。

### 2. 生成训练数据

```bash
python3 data/prepare_data.py \
    --cybergym-data ~/cybergym_data/data \
    --task-list data/task_list.json \
    --output train.parquet --difficulty level1
# 上传至集群 head 节点 /data/dataset/cybergym/
```

### 3. 部署到集群 12 节点

需分发文件（rollout 节点必须含工具实现）：
`cybergym_tools_verl.py`、`tool_config.yaml`、`cybergym_reward.py`、
`system_prompt.py`、`train_cybergym_multiturn.sh`、`train.parquet`

容器内统一路径 `/data/z00666713/deepseek0715/cybergym_integration/`，
并清理 `__pycache__`（否则旧字节码会遮蔽新代码）。

### 4. 最小链路验证

```bash
bash configs/train_cybergym_multiturn.sh \
    trainer.total_epochs=1 data.train_batch_size=1 actor_rollout_ref.rollout.n=4
```

验证清单：① 轨迹出现 `<tool_call>` ② `__num_turns__ > 1` ③ 工具真实执行
④ 模型引用工具结果 ⑤ reward 有 group 方差 ⑥ loss 正常。

### 5. 全量多轮训练

```bash
bash configs/train_cybergym_multiturn.sh trainer.total_epochs=5
```

## Reward 设计

| 条件 | 分数 | 说明 |
|------|------|------|
| 输出含 Python 代码块 | +0.1 | 格式分（保证 group 内方差） |
| vul 容器 crash（exit_code ≠ 0） | +1.0 | 核心奖励 |
| fix 容器不 crash | +0.5 | 精确命中目标漏洞 |
| fix 容器也 crash | -0.5 | 打错了 bug |
| Server 基础设施错误 | 不惩罚 | exit_code=-1 时仅计格式分 |

多轮模式下工具 step reward：crash +0.05 / valid PoC +0.1（最终分数仍由 reward 函数统一定）。

## 当前状态

- ✅ **单轮 GRPO 训练闭环跑通**（v12：step 零错误、轨迹正常、reward 链路通）
- ✅ CyberGym Server 部署 + 23/23 联调（延迟 0.19s）+ 10 任务镜像
- ✅ 多轮代码就绪（异步工具 / hermes prompt / tool_config / 训练脚本）
- 🔄 Phase 1 进行中：集群部署 → 最小链路验证 → 全量多轮训练

### 已修复的关键问题（详见 WORK_SUMMARY.md）

| 问题 | 修复 | 位置 |
|------|------|------|
| 权重同步 copy_d2d crash | vllm-ascend MoE kernel 布局检测 + 参数 revert | 12 节点 deepseek_v4.py |
| master_param KeyError | CPU offload 状态 fallback | 12 节点 distrib_optimizer.py |
| NPU OOM (56GB) | use_precision_aware_optimizer=True | 训练脚本 |
| Checkpoint shape 不匹配 | save_freq=0 | 训练脚本 |
| 工具阻塞 event loop | 原生 httpx.AsyncClient + asyncio 子进程 | cybergym_tools_verl.py |

## 设计决策

1. **verl 原生多轮而非 opencode+trajproxy**：训练模型自己生成轨迹，reward 才能回馈到它；外部黑盒 Agent 的轨迹训不到自己头上。trajproxy（黑盒轨迹捕获）仅在引入外部 Agent 时需要。
2. **CyberGym Server 作裁判**：官方验证服务，不可作弊、可复现、与 leaderboard 同一标准；容器 `network=none` 隔离，PoC hash 去重，无需自研容器管理。
3. **response_mask 机制**：LLM token mask=1 参与更新，工具返回 mask=0——模型只学决策，不学工具输出。
4. **hermes tool-call 格式**：prompt 内置格式示例；若模型不适应可一行切换 `multi_turn.format=gpt-oss|qwen3_coder`。
