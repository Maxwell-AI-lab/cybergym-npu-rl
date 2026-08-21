# Phase 1 方案：多轮 Agent 后训练跑通（CyberGym × verl tool_agent_loop）

> **目标**：DeepSeek V4 Flash 在 verl 原生 tool_agent_loop 下完成多轮工具交互训练——模型自主调用 read_file / execute_code / submit_poc，基于 CyberGym 返回结果迭代 PoC，reward 驱动 GRPO 更新。
> **前置**：单轮 v12 已跑通（证明训练基础设施 + reward 链路无误）。多轮是唯一新变量。

---

## 1. 选型

| 维度 | 选型 | 状态 | 说明 |
|------|------|------|------|
| 训练框架 | verl GRPO | ✅ 已跑通 | 不动 |
| 交互框架 | **verl tool_agent_loop** | 代码已写 | `@register("tool_agent")` 内置状态机 |
| Agent 运行时 | **无外部 Agent** | — | 不用 opencode / trajproxy / AgentSDK |
| 工具 | read_file / execute_code / submit_poc | 代码已写 | BaseTool 包装，见 `cybergym_tools_verl.py` |
| Tool call 格式 | hermes（首选），gpt-oss / qwen3_coder（备选） | ⏸ 待验证 | **最大风险点**，见 §3.1 |
| Reward | CyberGym 真实验证 | ✅ 已跑通 | 多轮场景取最后 PoC |
| 并行配置 | 完全不动 | ✅ 已锁定 | TP4/PP2/EP32 等 |

## 2. 多轮链路全景

```
vLLM 生成 Turn 1          verl 执行工具              进入上下文 (mask=0)
─────────────────         ─────────────────          ─────────────────
"先读漏洞描述"     ──►    read_file(desc.txt)  ──►  漏洞描述文本
"构造超长输入..."  ──►    execute_code(python) ──►  PoC bytes
"提交验证"        ──►    submit_poc(code)     ──►  exit_code=11 CRASH!
"验证修复版"      ──►    submit_poc(final=T)  ──►  VALID PoC!
                                             ──►  终止 (final / max_turns)
                                                      │
                     reward = f(最终PoC, CyberGym验证) ◄─ cybergym_reward.py
                                                      │
                     GRPO: mask=1 的 token 参与更新 ◄── response_mask
```

**关键机制**：`response_mask` —— LLM 生成的 token mask=1（参与 loss），工具返回的 token mask=0（不参与）。模型只学自己的决策（何时调什么工具、怎么写 PoC），不学工具输出。

## 3. 三大风险与预案

### 3.1 模型会不会发 hermes 格式 tool call？（最大风险）

**问题**：hermes 格式要求模型输出 `<tool_call>{"name":"submit_poc","arguments":{...}}</tool_call>`。DeepSeek V4 Flash 若不熟悉此格式，整条多轮链路空转（模型只输出文本，永不调工具，一轮就 TERMINATED）。

**验证方法（Step 3 第一优先检查）**：轨迹里搜 `<tool_call>`。

**预案（按顺序尝试）**：
1. **System prompt 显式示例**（首选，Step 1 就做）：在 prompt 里给完整格式示例
2. **切格式**：一行配置 `multi_turn.format="gpt-oss"` 或 `"qwen3_coder"`，verl 的 ToolParser 注册表内置三种
3. **检查 chat template**：`apply_chat_template` 传 tool_schemas 时，DeepSeek 官方模板可能自动注入工具说明——若模板已支持，prompt 里不用重复教

### 3.2 上下文长度预算

**问题**：8 轮 × (LLM 输出 + 工具返回) 容易超 4096。超长会被强制 TERMINATED，轨迹截断。

**预算表**（当前配置）：

| 项 | 配置值 | 说明 |
|----|--------|------|
| max_prompt_length | 4096 | system + task 描述 |
| max_response_length | 4096 | 所有轮 LLM 输出 + 工具返回总和 |
| max_tool_response_length | 2048 | 单次工具返回上限（middle 截断） |
| max_assistant_turns | 8 | 轮次上限 |

**预案**：若超长 → `max_assistant_turns=5` 或 `max_response_length=6144`（显存允许时）。

### 3.3 submit_poc 怎么知道 task_id？

**问题**：工具需要 task_id 提交 CyberGym，但工具只能从 `agent_data.messages` 里拿。

**方案（已实现 + 数据侧加固）**：
- `cybergym_tools_verl.py` 已用正则 `(arvo|oss-fuzz):\d+` 从消息里提取
- **数据侧保证**：user message 里明确包含 `Task ID: arvo:10400` 字样（Step 1 改 parquet 时确保）

## 4. 执行步骤

### Step 0：本地静态验证（不需集群，~15 min）

```bash
# 1. tool_config.yaml 语法验证
python3 -c "from omegaconf import OmegaConf; c=OmegaConf.load('verl_integration/tool_config.yaml'); print(c.tools[0].class_name)"

# 2. 工具类逻辑单测（mock BaseTool 接口）
python3 -c "
import asyncio, sys; sys.path.insert(0, '.')
# mock verl 模块后 import，验证 execute 逻辑
"
```

### Step 1：Prompt 与数据准备（本地，~30 min）

**1a. system_prompt.py 加 hermes 示例**：

```
## Tool Call Format

To call a tool, output exactly this format:

<tool_call>
{"name": "read_file", "arguments": {"path": "description.txt"}}
</tool_call>

You may include analysis text before the tool call. The tool result will be
provided in the next turn. When you have a working PoC, submit with
submit_poc(code=..., final=True).
```

**1b. parquet 加固**：确保 user message 含 `Task ID: arvo:xxxx`（供 submit_poc 正则提取）+ 漏洞描述全文（read_file 变为可选）。

**1c. 重新生成 parquet** 并上传 head 节点 `/data/dataset/cybergym/`。

### Step 2：部署 12 节点（~30 min）

需分发文件（head 直 cp，其余 scp + docker cp + 清 pycache）：

| 文件 | 说明 |
|------|------|
| `cybergym_tools_verl.py` | 工具实现（**rollout 节点必须**） |
| `tool_config.yaml` | 工具配置（**rollout 节点必须**） |
| `train_cybergym_multiturn.sh` | 启动脚本（head） |
| `cybergym_reward.py` | reward（已适配多轮，head） |
| `train.parquet`（新版） | 数据（head） |

**注意**：容器内路径统一 `/data/z00666713/deepseek0715/cybergym_integration/`，`tool_config.yaml` 里 `class_name: "verl_integration.cybergym_tools_verl.CyberGymReadFileTool"` 依赖 PYTHONPATH 含 `/data/z00666713/deepseek0715`（现有脚本已配置）。

### Step 3：最小链路验证（1 任务 × 1 batch × n=4，~1-2 h）

```bash
bash configs/train_cybergym_multiturn.sh \
    trainer.total_epochs=1 \
    data.train_batch_size=1 \
    actor_rollout_ref.rollout.n=4
```

**验证清单（按优先级）**：

| # | 检查项 | 看什么 | 判定 |
|---|--------|--------|------|
| 1 | **模型发 tool call** | 轨迹/log 搜 `<tool_call>` | 没有 → 走 §3.1 预案 |
| 2 | 状态机多轮运转 | `__num_turns__` > 1 | =1 → 模型没被工具结果带回 GENERATING |
| 3 | 工具真实执行 | log 搜 CyberGym 请求 / read_file 返回 | 无 → 查 class_name 加载 |
| 4 | 结果进入上下文 | Turn 2 输出引用了 Turn 1 工具结果 | 无 → 查 chat template 的 tool role |
| 5 | reward 正确 | `[REWARD-DBG]` 打印 turns 数 + score | 全 0 → 查 PoC 提取 |
| 6 | mask 正确 | loss 正常、无 NaN | NaN → mask/position_ids 问题 |

**通过标准**：#1-#4 全过 = 多轮链路通；#5-#6 过 = 训练语义正确。

### Step 4：问题修复迭代（预留 2-3 轮）

预期高频问题速查：

| 症状 | 原因 | 修复 |
|------|------|------|
| 无 `<tool_call>` 输出 | 模型不熟 hermes | 强化 prompt 示例 / 换 format |
| 一轮就终止 | 无 tool_call 被解析 | 确认 format 与模型输出匹配 |
| Trajectory 截断 | 超长 | 降 turns / 提长度 |
| submit_poc 报 no task_id | 正则没匹配 | 检查 prompt 里 Task ID 格式 |
| 工具类加载失败 | PYTHONPATH | 容器内验证 import |
| OOM | 长度增加 | 降 max_response_length / gpu_memory_utilization 微调 |

### Step 5：全量多轮训练

```bash
bash configs/train_cybergym_multiturn.sh trainer.total_epochs=5
```

**监控指标**（多轮特有）：
- `__num_turns__` 分布（平均轮数应 >2，说明模型在迭代）
- 工具调用频次（read_file / execute_code / submit_poc 各自计数）
- submit_poc 成功率随 step 变化
- reward mean/std + group 方差（GRPO 有梯度）
- infra error 比例（CyberGym 稳定性）

## 5. 成功标准（Phase 1 Exit Criteria）

| # | 标准 | 验证方式 |
|---|------|---------|
| 1 | 轨迹中出现真实工具调用 | log 搜 tool_call + 工具执行记录 |
| 2 | 多轮迭代行为（平均 turns ≥ 2） | `__num_turns__` 统计 |
| 3 | 模型基于工具结果调整策略 | 抽查轨迹：crash 后修改 PoC 再提交 |
| 4 | reward 正确计算且 group 有方差 | reward std > 0 |
| 5 | 连续 10+ steps 稳定训练 | console log |
| 6 | crash rate 相对单轮基线有变化 | 对比统计 |

**1-4 = 多轮链路跑通；5-6 = 多轮训练闭环跑通。**

## 6. 时间线

| 步骤 | 耗时 | 依赖 |
|------|------|------|
| Step 0 本地静态验证 | 15 min | 无 |
| Step 1 prompt/数据 | 30 min | 无 |
| Step 2 部署 12 节点 | 30 min | Step 1 |
| Step 3 最小验证 | 1-2 h | Step 2 |
| Step 4 迭代修复 | 2-3 轮 × 1 h | Step 3 发现的问题 |
| Step 5 全量训练 | 数小时 | Step 4 通过 |

**最快路径**：半天出最小验证结果，1-2 天全量训练。

## 7. 已就绪的代码资产

| 文件 | 状态 |
|------|------|
| `verl_integration/cybergym_tools_verl.py` | ✅ 3 个 BaseTool 已写 |
| `verl_integration/tool_config.yaml` | ✅ 已写 |
| `configs/train_cybergym_multiturn.sh` | ✅ 已写（multi_turn 全配置） |
| `verl_integration/cybergym_reward.py` | ✅ 已适配多轮（取最后 PoC + turns 打印） |
| `verl_integration/system_prompt.py` | ⏳ Step 1 加 hermes 示例 |
| `MULTITURN_PLAN.md` | ✅ 技术细节备查 |
