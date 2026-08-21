# 多轮 Agent 训练架构与调用流程

> 本文回答两个问题：**用了什么框架**（verl 原生 `tool_agent_loop`，零改动）和**一次训练到底怎么跑**（组件清单 + 全链路调用流程图）。
> 依据：verl 源码实证分析（`verl/experimental/agent_loop/`、`verl/tools/`）+ 我们已验证的 v12 单轮链路。

---

## 0. 结论先行

**是的，用的是 verl 原生多轮 Agent 框架**：`@register("tool_agent")` 注册的 `ToolAgentLoop` 状态机（verl 内置），通过配置启用，**没有修改任何 verl 源码**。我们的代码只以三种插件形式接入：

| 插件点 | 我们的文件 | verl 加载机制 |
|--------|-----------|--------------|
| 工具 | `cybergym_tools_verl.py`（3 个 BaseTool 子类） | `tool_config.yaml` → `initialize_tools_from_config()` importlib 动态加载 |
| Reward | `cybergym_reward.py` 的 `compute_score()` | `reward.custom_reward_function.path` 动态加载 |
| 数据 | `prepare_data.py` 生成的 parquet | 标准 verl 数据格式 |

---

## 1. 组件全景

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           我们写的代码（插件层）                              │
│                                                                             │
│  train_cybergym_multiturn.sh      ← 启动配置（multi_turn.enable=True 等）      │
│  tool_config.yaml                 ← 工具注册表（3 工具 → class_name 映射）      │
│  cybergym_tools_verl.py           ← ReadFile/SubmitPoc/ExecuteCode 三个工具    │
│  cybergym_reward.py               ← compute_score() 最终打分                  │
│  system_prompt.py / prepare_data.py ← prompt 模板 + parquet 生成              │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ 动态加载（path / YAML）
┌──────────────▼──────────────────────────────────────────────────────────────┐
│                    verl 框架（上游源码，未修改）                                │
│                                                                             │
│  ┌─ 训练编排 ─────────────────────────────────────────────────────────┐     │
│  │ verl.trainer.main_ppo → RayPPOTrainer                              │     │
│  │   · Rollout 生成 → Reward 打分 → GRPO advantage → 策略更新          │     │
│  │   · Megatron 3D 并行 actor + HCCL 权重同步回 vLLM                   │     │
│  └───────────────────────────────────────────────────────────────────┘     │
│  ┌─ 多轮 Agent（核心新增能力）────────────────────────────────────────┐     │
│  │ AgentLoopManager (Ray Actor 池，8 workers)                         │     │
│  │   └─ AgentLoopWorker                                               │     │
│  │       └─ ToolAgentLoop  @register("tool_agent")                    │     │
│  │           · 状态机: PENDING→GENERATING→PROCESSING_TOOLS→...→DONE   │     │
│  │           · AgentData: 每条轨迹的完整状态容器                        │     │
│  │ · ToolParser (hermes/gpt-oss/qwen3_coder)  ← 解析模型的工具调用      │     │
│  │ · BaseTool 基类                            ← 我们工具的父类         │     │
│  │ · initialize_tools_from_config()           ← YAML 工具加载器        │     │
│  │ · apply_chat_template(messages, tools)      ← 对话+工具→token ids   │     │
│  └───────────────────────────────────────────────────────────────────┘     │
│  ┌─ 推理 ───────────────────────────────────────────────────────────┐      │
│  │ vLLM Server Manager (rollout 节点 ×4, TP=8/DP=4)                  │     │
│  │   · GlobalRequestLoadBalancer: sticky session（同一轨迹多轮请求      │     │
│  │     LRU 路由到同一 server → 前缀缓存命中，避免重算 KV cache）        │     │
│  │   · DSpark 投机解码 num_speculative_tokens=5                       │     │
│  └───────────────────────────────────────────────────────────────────┘     │
│  ┌─ Reward ─────────────────────────────────────────────────────────┐      │
│  │ BatchRewardManager.verify() → 每个 sample 调 compute_score()       │     │
│  │   · reward 写在序列最后一个有效 token 位置                           │     │
│  └───────────────────────────────────────────────────────────────────┘     │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ HTTP (submit_poc 工具 / compute_score)
┌──────────────▼──────────────────────────────────────────────────────────────┐
│                CyberGym Server（官方验证服务，x86 192.168.0.100:8666）        │
│  FastAPI → checksum 校验 → PoC hash 查 SQLite 缓存 → docker create/start/   │
│  wait/remove（vul 或 fix 镜像, network=none, timeout 10s）→ 返回 exit_code  │
└─────────────────────────────────────────────────────────────────────────────┘
```

**明确不用的**：opencode（外部黑盒 Agent）、trajproxy（黑盒轨迹捕获代理）、Ascend AgentSDK/Aura、SEGym 容器池——这些是生产化/外部 Agent 场景的组件，多轮训练语义下不需要（详见 PLAN.md §1 选型）。

---

## 2. 一次完整训练 Step 的调用流程

```
┌──────────────────────────────────────────────────────────────────────┐
│ ① Trainer 发起 Rollout                                                │
│    parquet 取 batch(8 prompt) × n(4) = 32 条轨迹                       │
│    分发到 AgentLoopWorker（Ray Actor, 每条轨迹一个 ToolAgentLoop 实例）   │
├──────────────────────────────────────────────────────────────────────┤
│ ② 多轮生成（§3 详展开）                    ┌─ 并发: 32 条轨迹在          │
│    每条轨迹内部:                          │  asyncio event loop 上      │
│      LLM 生成 → 解析 tool_call            │  并行推进                   │
│      → await 工具执行(异步) ──────────────┘                             │
│      → 工具结果回填 → 再生成 → ... → 终止                                │
│    产出: prompt_ids + response_mask + response_logprobs + messages      │
├──────────────────────────────────────────────────────────────────────┤
│ ③ Reward 打分（batch 级）                                              │
│    BatchRewardManager.verify()                                        │
│      └─ 对每条轨迹调 cybergym_reward.compute_score(                    │
│           data_source="cybergym",                                     │
│           solution_str=<整条轨迹文本>,                                  │
│           ground_truth=<task_id>,                                      │
│ extra_info / __num_turns__ / tool_rewards ...)                        │
│      └─ 提取最后 PoC → HTTP POST CyberGym → crash 判分                  │
│    reward 写入 reward_tensor[序列最后有效 token 位置]                    │
├──────────────────────────────────────────────────────────────────────┤
│ ④ GRPO 更新                                                           │
│    group=同一 prompt 的 4 条采样 → 组内 reward 标准化 = advantage        │
│    (全 0 或全 1 的 group advantage=0，无梯度——依赖工具 step reward        │
│     和格式分保证方差)                                                    │
│    loss 只对 response_mask==1 的 token 计算（LLM 决策 token）            │
│    Megatron 反传 → optimizer step                                       │
├──────────────────────────────────────────────────────────────────────┤
│ ⑤ 权重同步                                                             │
│    新权重 → HCCL broadcast → 4 个 rollout 节点 vLLM 热加载               │
│    （vllm-ascend MoE kernel 布局 revert 补丁已修，v12 验证通过）          │
├──────────────────────────────────────────────────────────────────────┤
│ ⑥ 回到 ①，下一个 step                                                   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. ToolAgentLoop 状态机详解（单条轨迹内部）

```
                    ┌─────────────────────────────────────────────┐
                    │ 初始化: messages = parquet 的 [system,user]   │
                    │ tools   = tool_config.yaml 加载的 3 个实例    │
                    └──────────────────────┬──────────────────────┘
                                           ▼
   ┌────────┐   apply_chat_template(messages, tool_schemas)   ┌───────────┐
   │PENDING │ ─────────────────────────────────────────────► │GENERATING │
   └────────┘          prompt_ids = 模板编码结果               └─────┬─────┘
                                                              vLLM 生成 │
                     ┌────────────────────────────────────────────────┤
                     │ assistant_turns += 1                          │
                     │ response_ids 追加进 prompt_ids                │
                     │ response_mask 追加 [1]*len  ◄── LLM token     │
                     │                                                │
                     │ 终止判定(任一满足 → TERMINATED):                 │
                     │   · 总 response token ≥ max_response_length   │
                     │   · assistant_turns ≥ max_assistant_turns(8)  │
                     │   · user_turns ≥ max_user_turns(8)            │
                     │                                                │
                     │ ToolParser(hermes).extract_tool_calls()       │
                     └──────┬────────────────────────┬───────────────┘
                    有 tool_call                无 tool_call
                            ▼                            ▼
              ┌──────────────────────┐            ┌────────────┐
              │   PROCESSING_TOOLS   │            │ TERMINATED │
              │ 并行执行(≤max_        │            └────────────┘
              │ parallel_calls=1):   │
              │  for call in calls:  │
              │   tool.create()      │
              │   tool.execute() ────┼──► §4 工具执行流程
              │   tool.release()     │      (await 异步, 不阻塞
              │                      │       其他 31 条轨迹)
              │ ToolResponse.text    │
              │  >2048 字符 → middle │
              │  截断                │
              │ 工具结果编码后追加:    │
              │  response_mask       │
              │  += [0]*len ◄── 工具  │
              │  token 不参与 loss    │
              │ user_turns += 1       │
              └──────────┬───────────┘
                         │ 未超长
                         ▼
                   回到 GENERATING（下一轮）
```

**AgentData（贯穿全程的状态容器）关键字段**：

| 字段 | 含义 | 消费方 |
|------|------|--------|
| `messages` | 完整对话历史（含 tool 角色） | chat template / 工具提取 task_id |
| `prompt_ids` | 不断增长的 token 序列 | 训练 input_ids |
| `response_mask` | 1=LLM 生成 / 0=工具返回 | loss mask（核心训练语义） |
| `response_logprobs` | 生成 token 的 logprob（工具位置填 0） | PPO/GRPO ratio |
| `tool_rewards` | 每次 execute 的 step reward（crash+0.05/valid+0.1） | 传给 reward 函数参考 |
| `turn_scores` / `extra_fields` | `__num_turns__` 等统计 | 监控 + reward kwargs |

---

## 4. 工具执行流程（以 submit_poc 为例）

```
ToolAgentLoop (rollout 节点, asyncio)
  │ await submitPocTool.execute(instance_id, {code, final})
  ▼
cybergym_tools_verl.py
  ① task_id 解析: 对话中 "Task ID: arvo:10400" → regex (arvo|oss-fuzz):\d+
  ② code → PoC bytes:
       python 代码 → asyncio.create_subprocess_exec("python3", "-c", ...)
                     捕获 stdout 作为 PoC 二进制
       失败则依次尝试 hex / base64 / 原文编码
  ③ 共享 httpx.AsyncClient (连接池) POST /submit-vul
       └─► CyberGym Server (x86:8666)
             a. checksum = sha256(task_id+agent_id+salt) 校验
             b. sha256(poc) 查 SQLite —— 同轨迹重复提交直接回缓存
             c. docker create(n132/arvo:10400-vul,
                  cmd="timeout 10s /bin/arvo", net=none, 挂载 poc)
                → start → wait(≤60s) → exit_code → remove(force)
  ④ vul crash 且非 infra 错误 → 再 POST /submit-fix（同 PoC 跑修复版）
  ⑤ 组装 ToolResponse 文本:
       "Status: CRASH DETECTED — VALID PoC (patched does NOT crash)"
       / "NO CRASH (exit_code=0)" / "SERVER ERROR (not your fault)"
     step_reward: valid=+0.1 / 仅 crash=+0.05 / 其他 0
  ▼
返回 ToolAgentLoop → 编码进对话 → 模型下一轮看到结果 → 迭代 PoC
```

read_file：`asyncio.to_thread` 读 rollout 节点本地任务目录（可选辅助工具）。
execute_code：`asyncio.create_subprocess_exec` 沙盒跑 Python，超时 10s kill。

---

## 5. Token / Mask 布局（训练语义核心）

```
序列 = [system][user][assistant₁][tool₁][assistant₂][tool₂]...[assistantₙ]
        └── prompt ──┘└──────────── response 区域 ─────────────┘

mask:    0 0 0 0 0 0   1 1 1 1 1 1   0 0 0 0   1 1 1 1 1   0 0 0 0   1 1 1 1
                       └─ LLM 生成 ─┘ └工具返回┘  └─ LLM ─┘  └工具┘   └ LLM ┘

loss / logprob 只对 mask=1 的 token 计算：
  模型学到的是「何时调工具、传什么参数、怎么写 PoC、拿到结果后怎么改」
  工具输出（源码内容、crash 日志）不进入梯度 —— 它是环境观测，不是策略
reward 写在最后一个有效 token 的位置（整条轨迹一个分）
```

---

## 6. 关键配置 ↔ 框架行为对照

| 配置（train_cybergym_multiturn.sh） | verl 里的作用点 |
|--------------------------------------|----------------|
| `multi_turn.enable=True` | 激活 AgentLoopManager 路径（替代单轮直接生成） |
| `multi_turn.tool_config_path` | `initialize_tools_from_config()` → OmegaConf → importlib 实例化 3 工具 |
| `agent.default_agent_loop="tool_agent"` | 从 `@register` 注册表取 ToolAgentLoop 类（hydra instantiate） |
| `multi_turn.format="hermes"` | ToolParser 注册表选 hermes 解析器（`<tool_call>{json}</tool_call>`），可一行切 gpt-oss / qwen3_coder |
| `max_assistant_turns / max_user_turns=8` | GENERATING/PROCESSING_TOOLS 的终止条件 |
| `max_tool_response_length=2048` + `truncate_side=middle` | 工具返回截断（防源码/日志撑爆上下文） |
| `max_parallel_calls=1` | 每轮最多并行工具调用数 |
| `max_response_length=4096` | response 区 token 总预算（含工具返回） |
| `rollout.n=4` | GRPO group size（同一 prompt 4 条轨迹组内对比） |
| `reward.custom_reward_function.path` | reward.py 动态加载，`compute_score` 接收整条轨迹 + `__num_turns__` |

---

## 7. 物理部署视图

```
192.168.0.36 (head)                      容器 cybergym-baseline-zhouzhi
├─ main_ppo 启动 / Ray head (:6766)
├─ /data/dataset/cybergym/train.parquet
└─ /data/z00666713/deepseek0715/cybergym_integration/
     ├─ configs/train_cybergym_multiturn.sh
     └─ verl_integration/cybergym_reward.py        ← reward 在 trainer 侧执行

192.168.0.41,51,88,89,189,47,50 (train×7) Megatron actor/ref, TP4/PP2/EP32

192.168.0.17,195,85,48 (rollout×4)       ← 工具在这里执行!
├─ vLLM server (TP=8/DP=4, DSpark)
├─ AgentLoopWorker (Ray actor) × 8
└─ /data/z00666713/deepseek0715/cybergym_integration/verl_integration/
     ├─ cybergym_tools_verl.py   ← 必须部署（importlib 加载）
     ├─ tool_config.yaml          ← 必须部署（路径引用）
     └─ cybergym_tools.py

192.168.0.100 (x86)
├─ CyberGym Server :8666 (FastAPI + SQLite /data/cybergym/poc.db)
└─ Docker: 10 任务 × vul/fix 镜像（network=none 按需创建销毁）
```

> 部署要点：rollout 节点必须同时有 `cybergym_tools_verl.py` 和 `tool_config.yaml`（工具在 rollout 侧的 worker 进程内执行）；替换文件后必须清 `__pycache__`（12 节点同步踩过坑）。

---

## 附录：chat template 在多轮流程中的参与点（实测版）

template 只负责**输入侧编码**（messages → token），不参与模型输出。多轮中**每轮重跑一次**，取增量 token 追加：

```
轮次         模板参与                    产出
─────────────────────────────────────────────────────────────
Turn 0 初始   ★ apply_chat_template     prompt_ids (mask=0)
              ([system,user])
Turn 1 生成   ✗ vLLM 自由生成            response_ids (mask=1)
             ✗ Parser 解析工具调用       (skip_special_tokens=False)
             ✗ 工具执行                  ToolResponse
回填         ★ apply_chat_template     增量 token (mask=0)
              (完整 messages 含 tool 角色)  ↑ 模板渲染 <tool_result>
Turn 2 生成   ✗ vLLM 生成               ...循环
─────────────────────────────────────────────────────────────
Reward/训练   ✗ decode 拼接 + mask 过滤   loss 只对 mask=1
```

实测渲染结果（DS4-Flash 部署版模板）：
- system：渲染（前缀拼接在首个 `<｜User｜>` 前）✓
- user：`<｜User｜>{content}<｜Assistant｜><think>` ✓
- tool 角色：`<｜User｜><tool_result>{content}</tool_result><｜Assistant｜><think>` ✓
- **tools 参数：被模板忽略**（带不带渲染结果一样）✗ → 工具定义只能靠 system prompt 文本

两个由此产生的坑（已在 S5 修复）：
1. 模型输出方言（XML）与模板无关，parser 需按模型 SFT 行为适配（三方言）
2. verl L268 用 skip_special_tokens=True decode → 原生标记被剥，模型输出呈"残缺官方格式"，parser 需宽松匹配
