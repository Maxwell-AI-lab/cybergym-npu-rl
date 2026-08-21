# VERL 原生多轮 Agent 训练方案 — CyberGym 漏洞分析

> **目标**：用 verl 内置 tool_agent_loop 框架实现 CyberGym 多轮漏洞分析训练，不依赖 opencode/trajproxy
> **前置**：单轮 GRPO v12 已跑通（step:1 零错误）

---

## 1. 核心设计

### 1.1 为什么用 verl 原生方案

| 对比项 | verl 原生 | opencode + trajproxy |
|--------|-----------|---------------------|
| **训练语义** | ✅ 训练模型自己生成轨迹，reward 直接回馈 | ❌ 外部模型生成，训练模型学不到 |
| **架构复杂度** | ✅ 只需 3 个文件（BaseTool + YAML + 脚本改动） | ❌ 需部署 PostgreSQL + Ray Workers + Nginx |
| **logprob 精度** | ✅ vLLM 直接提供，零误差 | ⚠️ trajproxy 拦截，保真度 >0.99 |
| **工具能力** | 纯 Python 函数（read/submit/execute） | OpenCode 完整工具链（bash/read/write） |
| **适用阶段** | Phase 2 快速验证 | Phase 3+ 生产化 |

### 1.2 多轮交互流程

```
vLLM (训练中的 DeepSeek V4 Flash)
    │
    ├── Turn 1: "我来分析这个漏洞"
    │   └── tool_call: read_file("description.txt")
    │   └── ToolResponse: 漏洞描述文本 (mask=0)
    │
    ├── Turn 2: "这是个 buffer overflow，我需要构造超长输入"
    │   └── tool_call: execute_code("import struct; print(b'A'*100 + struct.pack('<I', 0xdeadbeef))")
    │   └── ToolResponse: PoC bytes hex dump (mask=0)
    │
    ├── Turn 3: "提交测试一下"
    │   └── tool_call: submit_poc(code="...", final=False)
    │   └── ToolResponse: "CRASH DETECTED, exit_code=11" (mask=0)
    │
    ├── Turn 4: "Crash 了！再验证修复版本"
    │   └── tool_call: submit_poc(code="...", final=True)
    │   └── ToolResponse: "VALID PoC! (does NOT crash patched version)" (mask=0)
    │
    └── TERMINATED (final=True 或 max_turns=8)
         └── reward 函数提取最终 PoC → CyberGym 验证 → score
```

**response_mask 机制**：
- LLM 生成的 token: mask=1（参与 loss 计算）
- 工具返回的 token: mask=0（不参与 loss 计算）
- 这确保模型只学习自己的推理和工具调用策略

### 1.3 三个工具的 step_reward 设计

| 工具 | step_reward | 说明 |
|------|-------------|------|
| read_file | 0.0 | 中性，读文件不直接影响 reward |
| execute_code | 0.0 | 中性，代码执行不直接影响 reward |
| submit_poc | 0.0 ~ 0.1 | crash=+0.05, valid PoC=+0.1 |

**最终 reward** 由 `cybergym_reward.py` 的 `compute_score()` 计算，基于完整轨迹中最后一次 submit_poc 的结果。

---

## 2. 已完成的代码

### 2.1 文件清单

| 文件 | 用途 | 状态 |
|------|------|------|
| `verl_integration/cybergym_tools_verl.py` | 3 个 BaseTool 子类 | ✅ 已写 |
| `verl_integration/tool_config.yaml` | 工具配置（OmegaConf） | ✅ 已写 |
| `configs/train_cybergym_multiturn.sh` | 多轮训练启动脚本 | ✅ 已写 |
| `verl_integration/cybergym_reward.py` | reward 函数（已适配多轮） | ✅ 已改 |
| `verl_integration/system_prompt.py` | system prompt（需微调） | ⏳ 待改 |

### 2.2 cybergym_tools_verl.py 详解

三个 BaseTool 子类，包装现有的纯 Python 工具函数：

```python
class CyberGymReadFileTool(BaseTool):
    """读任务文件：description.txt, README.md, error.txt, patch.diff"""
    async def create(instance_id) -> (instance_id, ToolResponse)
    async def execute(instance_id, parameters) -> (ToolResponse, step_reward=0.0, metrics)
    async def calc_reward(instance_id) -> 0.0
    async def release(instance_id) -> None

class CyberGymSubmitPocTool(BaseTool):
    """提交 PoC 到 CyberGym Server，返回 crash/no-crash 结果"""
    async def create(instance_id) -> (instance_id, ToolResponse)
    async def execute(instance_id, parameters) -> (ToolResponse, step_reward, metrics)
        # step_reward: crash=+0.05, valid_poc=+0.1, no_crash=0.0
    async def calc_reward(instance_id) -> 0.0
    async def release(instance_id) -> None

class CyberGymExecuteCodeTool(BaseTool):
    """沙盒执行 Python 代码，用于构造 PoC bytes、分析 hex dump 等"""
    async def create(instance_id) -> (instance_id, ToolResponse)
    async def execute(instance_id, parameters) -> (ToolResponse, step_reward=0.0, metrics)
    async def calc_reward(instance_id) -> 0.0
    async def release(instance_id) -> None
```

### 2.3 tool_config.yaml 格式

```yaml
tools:
  - class_name: "verl_integration.cybergym_tools_verl.CyberGymReadFileTool"
    config: { type: native, task_dir: "/tmp/cybergym_tasks" }
    tool_schema:
      type: "function"
      function:
        name: "read_file"
        description: "..."
        parameters: { type: "object", properties: {...}, required: [...] }

  - class_name: "verl_integration.cybergym_tools_verl.CyberGymSubmitPocTool"
    config: { type: native, server_url: "http://localhost:8666" }
    tool_schema: { ... }

  - class_name: "verl_integration.cybergym_tools_verl.CyberGymExecuteCodeTool"
    config: { type: native, timeout: 10 }
    tool_schema: { ... }
```

### 2.4 训练脚本关键改动（对比单轮）

```bash
# 新增 Multi-Turn 配置
MULTI_TURN_CONFIG=(
    actor_rollout_ref.rollout.multi_turn.enable=True
    actor_rollout_ref.rollout.multi_turn.tool_config_path="${TOOL_CONFIG_PATH}"
    actor_rollout_ref.rollout.multi_turn.max_assistant_turns=8
    actor_rollout_ref.rollout.multi_turn.max_user_turns=8
    actor_rollout_ref.rollout.multi_turn.max_parallel_calls=1
    actor_rollout_ref.rollout.multi_turn.max_tool_response_length=2048
    actor_rollout_ref.rollout.multi_turn.tool_response_truncate_side="middle"
    actor_rollout_ref.rollout.multi_turn.format="hermes"
)

AGENT_CONFIG=(
    agent.default_agent_loop="tool_agent"
)

# 长度调整
max_prompt_length=4096      # 单轮 1024 → 4096 (system prompt + tool schemas)
max_response_length=4096    # 单轮 1536 → 4096 (多轮需要更多空间)
max_model_len=8192          # prompt + response

# Batch 调整
n_resp_per_prompt=4         # 单轮 8 → 4 (多轮更贵)
```

---

## 3. 实施步骤

### Step 1: System Prompt 微调

**目标**：让模型知道有哪些工具可用，以及如何正确使用。

当前 `system_prompt.py` 已经描述了工具用法，但需要：
1. 明确 tool call 格式（hermes: `<tool_call>{...}
</think>

`）
2. 添加工作流示例
3. 强调 `submit_poc(final=True)` 表示最终答案

**改动**：在 `system_prompt.py` 的 SYSTEM_PROMPT 中增加 hermes 格式示例。

### Step 2: 部署到 12 节点

需要分发到所有 12 个节点（容器 `cybergym-baseline-zhouzhi`）的文件：

| 文件 | 容器内目标路径 |
|------|---------------|
| `cybergym_tools_verl.py` | `/data/z00666713/deepseek0715/cybergym_integration/verl_integration/` |
| `tool_config.yaml` | `/data/z00666713/deepseek0715/cybergym_integration/verl_integration/` |
| `train_cybergym_multiturn.sh` | `/data/z00666713/deepseek0715/cybergym_integration/configs/` |
| `cybergym_reward.py`（已改） | `/data/z00666713/deepseek0715/cybergym_integration/verl_integration/` |
| `system_prompt.py`（已改） | `/data/z00666713/deepseek0715/cybergym_integration/verl_integration/` |

**分发命令**（从 head 节点 .36 执行）：

```bash
CNAME="cybergym-baseline-zhouzhi"
LOCAL_BASE="/data/z00666713/deepseek0715/cybergym_integration"
TRAIN_NODES="41 51 88 89 189 47 50"
ROLLOUT_NODES="17 195 85 48"
ALL_NODES="$TRAIN_NODES $ROLLOUT_NODES"

# 1. Head 节点直接 docker cp
docker cp $LOCAL_BASE/verl_integration/cybergym_tools_verl.py $CNAME:$LOCAL_BASE/verl_integration/
docker cp $LOCAL_BASE/verl_integration/tool_config.yaml $CNAME:$LOCAL_BASE/verl_integration/
docker cp $LOCAL_BASE/configs/train_cybergym_multiturn.sh $CNAME:$LOCAL_BASE/configs/
docker cp $LOCAL_BASE/verl_integration/cybergym_reward.py $CNAME:$LOCAL_BASE/verl_integration/

# 2. 其他节点 scp + docker cp
for ip in $ALL_NODES; do
  scp $LOCAL_BASE/verl_integration/cybergym_tools_verl.py root@192.168.0.$ip:$LOCAL_BASE/verl_integration/
  scp $LOCAL_BASE/verl_integration/tool_config.yaml root@192.168.0.$ip:$LOCAL_BASE/verl_integration/
  scp $LOCAL_BASE/configs/train_cybergym_multiturn.sh root@192.168.0.$ip:$LOCAL_BASE/configs/
  scp $LOCAL_BASE/verl_integration/cybergym_reward.py root@192.168.0.$ip:$LOCAL_BASE/verl_integration/
  ssh root@192.168.0.$ip "
    docker cp $LOCAL_BASE/verl_integration/cybergym_tools_verl.py $CNAME:$LOCAL_BASE/verl_integration/
    docker cp $LOCAL_BASE/verl_integration/tool_config.yaml $CNAME:$LOCAL_BASE/verl_integration/
    docker cp $LOCAL_BASE/configs/train_cybergym_multiturn.sh $CNAME:$LOCAL_BASE/configs/
    docker cp $LOCAL_BASE/verl_integration/cybergym_reward.py $CNAME:$LOCAL_BASE/verl_integration/
    docker exec $CNAME find $LOCAL_BASE -name '__pycache__' -exec rm -rf {} + 2>/dev/null
  " &
done
wait
```

### Step 3: 准备任务文件目录

工具需要读取任务文件（description.txt 等）。需要在每个 rollout 节点准备：

```bash
# 在 x86 服务器上已有的任务数据
# 路径: /data/cybergym/tasks/arvo_10400/description.txt 等

# 需要在训练集群每个节点创建 /tmp/cybergym_tasks/ 目录
# 包含当前 batch 所有任务的文件
```

**方案**：在 reward 函数或 tool 的 create() 中，从 `ground_truth` (task_id) 动态下载任务文件。

### Step 4: 最小链路验证

**目标**：1 个任务 × 1 个 batch × 4 rollouts，验证多轮流程跑通。

```bash
# 在 head 节点 (.36)
cd /data/z00666713/deepseek0715
bash cybergym_integration/configs/train_cybergym_multiturn.sh \
    trainer.total_epochs=1 \
    trainer.val_before_train=False \
    data.train_batch_size=1 \
    actor_rollout_ref.rollout.n=4
```

**验证清单**：
- [ ] ToolAgentLoop 状态机正常进入 GENERATING → PROCESSING_TOOLS → GENERATING
- [ ] 工具调用被正确解析（hermes 格式）
- [ ] read_file 返回文件内容（mask=0）
- [ ] submit_poc 返回 CyberGym 验证结果
- [ ] execute_code 返回沙盒执行输出
- [ ] 最终 reward 正确计算
- [ ] 无 OOM / crash

### Step 5: 全量训练

**目标**：9 个任务 × n=4 rollouts，完整 GRPO 训练。

```bash
bash cybergym_integration/configs/train_cybergym_multiturn.sh
```

**监控指标**：
- TensorBoard: `reward/mean`, `reward/std`, `policy/loss`, `policy/kl`
- 多轮统计: `__num_turns__` 分布（平均轮数、最大轮数）
- 工具调用统计: read_file / submit_poc / execute_code 调用频次
- Pearson correlation（reward 和 advantage 的相关性）
- vul_crash_rate（每 N 步统计一次）

---

## 4. 潜在问题与应对

### 4.1 任务文件怎么传给工具？

**问题**：`read_file("description.txt")` 需要知道任务文件在哪个目录。

**方案**：
1. 在 `prepare_data.py` 生成 parquet 时，把任务文件内容嵌入 prompt 的 user message 中
2. 或者在 tool 的 `create()` 中，根据 `ground_truth` (task_id) 从固定路径读取
3. 或者用环境变量 `CYBERGYM_TASK_DIR` 指向预部署的任务目录

**推荐方案 1**（最简单）：把 description.txt 内容直接放在 user prompt 中，`read_file` 工具作为可选辅助（读 error.txt / patch.diff 等补充信息）。

### 4.2 模型不知道 tool call 格式？

**问题**：DeepSeek V4 Flash 可能不熟悉 hermes 格式的 `<tool_call>{...}
</think>

`。

**方案**：
1. 在 system prompt 中明确给出格式示例
2. 在 prompt 的 few-shot 中包含一个完整的工具调用示例
3. 如果 hermes 不行，切换到 `gpt-oss` 或 `qwen3_coder` 格式

### 4.3 多轮导致 response 超长？

**问题**：8 轮交互，每轮 LLM 生成 + 工具响应，总 token 数可能超过 `max_response_length=4096`。

**方案**：
1. `max_tool_response_length=2048` 限制工具响应长度（已配置）
2. `tool_response_truncate_side="middle"` 中间截断保留头尾
3. 如果还是超长，降低 `max_assistant_turns` 到 5
4. 或者提高 `max_response_length` 到 8192（需要更多显存）

### 4.4 CyberGym rate limit？

**问题**：batch=8 × n=4 = 32 个 rollout，每个可能调用 2-3 次 submit_poc，总计 ~100 次请求。

**当前配置**：rate limit = 200 req/60s（已调高），足够。

### 4.5 工具执行在哪个节点？

**问题**：`execute_code` 和 `submit_poc` 需要访问网络和执行 Python 代码。

**答案**：工具在 rollout 节点（.17/.195/.85/.48）的 verl worker 进程内执行。需要确保：
1. Rollout 节点能访问 CyberGym Server（192.168.0.100:8666）—— 已验证
2. Rollout 节点有 python3 可用 —— 容器内已有

---

## 5. 后续优化方向

### 5.1 异步训练（Phase 3）

当前是同步模式（rollout → reward → train → rollout），高延迟评估下 NPU 利用率低。

升级为 VERL Fully Async Trainer：
- Rollout Worker 持续采样，不等整批齐
- TransferQueue 经验队列
- Trainer 有数据就更新
- max_staleness=2 + rollout correction

### 5.2 更丰富的工具（Phase 3+）

当前只有 3 个工具。可以扩展：
- `analyze_source(code)`: 调用静态分析工具（cppcheck, clang-tidy）
- `compile_and_run(source, input)`: 编译 C 代码并运行（需要容器）
- `search_cve(keyword)`: 搜索 CVE 数据库

### 5.3 课程学习

从简单到难：
- Phase 2a: 只用 level3 任务（有 patch，最简单）
- Phase 2b: 加入 level2 任务（有 error.txt）
- Phase 2c: 加入 level1 任务（只有 description）
- Phase 2d: 挑战 level0（纯逆向）

### 5.4 评估对比

用 opencode + deepseek API 跑同样 10 个任务，作为 baseline 对比：
- 训练前: verl 单轮 crash rate vs opencode crash rate
- 训练后: verl 多轮 crash rate vs opencode crash rate
- 目标: 训练后 verl 多轮 ≥ opencode

---

## 6. 时间线

| 阶段 | 任务 | 预计时间 | 依赖 |
|------|------|---------|------|
| **Step 1** | System prompt 微调 | 30 min | 无 |
| **Step 2** | 部署到 12 节点 | 30 min | Step 1 |
| **Step 3** | 准备任务文件目录 | 30 min | 无 |
| **Step 4** | 最小链路验证（1 任务 × 1 batch） | 1-2 hour | Step 1-3 |
| **Step 5** | 全量训练（9 任务 × 多 epoch） | 数小时-数天 | Step 4 通过 |

**总计**：半天到一天可跑通多轮训练。

---

## 7. 总结

**VERL 原生多轮方案**是当前最优选择：
- ✅ 训练语义正确（模型自己生成轨迹）
- ✅ 架构简单（3 个文件 + 脚本改动）
- ✅ 已有代码基础（v12 单轮已通）
- ✅ 快速验证（半天跑通）

**不依赖 opencode/trajproxy**，这些留给 Phase 3+ 生产化阶段。
