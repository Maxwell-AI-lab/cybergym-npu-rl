# CyberGym + DeepSeek V4 Flash GRPO 后训练集成方案

## 1. 项目目标

将 [CyberGym](https://github.com/sunblaze-ucb/cybergym)（UC Berkeley Dawn Song 组，ICLR 2026）网络安全漏洞分析评测框架接入当前 DeepSeek V4 Flash GRPO 训练流水线。

**核心思路**：DeepSeek 模型分析真实漏洞 → 生成 PoC → CyberGym 容器验证 → GRPO 强化学习提升漏洞发现能力。

**实施策略**：先做 inference-only 基线评估，再跑单轮 GRPO 训练验证 reward signal 有效，最后升级到多轮 Agent 交互。

## 2. 硬件资源

| 角色 | 机器 | 规格 | 用途 |
|------|------|------|------|
| 训练集群 | 12x Ascend 910B (aarch64) | 64 NPUs | verl GRPO 训练 + vLLM 推理 |
| CyberGym Server | x86 服务器（与 NPU 同网段） | 32C/64GB/500GB+ | 漏洞验证容器 + FastAPI Server |
| 跳板 | Relay (119.8.234.170, aarch64) | - | 数据中转 |

## 3. 三份源码的关系

整个项目涉及三份代码，**两份上游源码不改，一份是我们写的集成代码**：

```
┌─────────────────────────────────────────────────────────────────────┐
│                        上游源码（不改）                                │
│                                                                     │
│  ┌─────────────────────────┐    ┌───────────────────────────────┐   │
│  │ verl (训练框架)           │    │ CyberGym (验证框架)            │   │
│  │ server_code/verl/       │    │ cybergym/                     │   │
│  │                         │    │                               │   │
│  │ - GRPO 训练循环          │    │ - FastAPI Server (:8666)      │   │
│  │ - vLLM 推理 (Rollout)   │    │ - Docker 容器管理              │   │
│  │ - Tool Agent Loop       │    │ - PoC 提交验证                 │   │
│  │ - Reward Manager        │    │ - SQLite 记录                  │   │
│  └────────┬────────────────┘    └──────────┬────────────────────┘   │
│           │ 动态加载                         │ HTTP 调用               │
└───────────┼─────────────────────────────────┼───────────────────────┘
            │                                 │
┌───────────┼─────────────────────────────────┼───────────────────────┐
│           ▼                                 ▼                       │
│  ┌────────────────────────────────────────────────────────────┐     │
│  │             我们的集成代码（cybergym_integration/）           │     │
│  │                                                            │     │
│  │  cybergym_reward.py ──reward.custom_reward_function.path──>│     │
│  │  cybergym_tools.py  ──tool_config.yaml────────────────────>│     │
│  │  train_cybergym.sh  ──python3 -m verl.trainer.main_ppo────>│     │
│  │  prepare_data.py    ──生成 parquet 训练数据                 │     │
│  │  setup_x86.sh       ──部署 CyberGym Server                 │     │
│  └────────────────────────────────────────────────────────────┘     │
│                        集成代码（要写）                               │
└─────────────────────────────────────────────────────────────────────┘
```

## 4. 系统架构

### 4.1 整体架构

```
训练集群 (910B aarch64, 192.168.0.x)              x86 服务器 (同网段)
┌──────────────┐  HCCL broadcast  ┌────────────┐   ┌──────────────────┐
│  8 Train 节点 │ ───────────────> │ 4 Rollout  │   │ CyberGym Server  │
│  (Megatron)  │   weight sync    │ (vLLM)     │   │ (FastAPI :8666)  │
│  GRPO update │                  │            │──>│                  │
└──────────────┘                  └─────┬──────┘   │ Docker × 20     │
                                        │          │ (10 vul + 10 fix)│
                              reward HTTP POST      │                  │
                              /submit-vul           └────────┬─────────┘
                                        │                    │
                                        ▼                    │
                              ┌──────────────────┐           │
                              │ cybergym_reward  │  docker run│
                              │ .py              │  容器验证   │
                              │ (custom reward)  │◄──────────┘
                              └──────────────────┘  exit_code
```

### 4.2 单轮模式（Phase 1 先验证）

```
Parquet 一行                          vLLM 推理                        Reward 打分
┌──────────────┐                    ┌──────────────┐                 ┌──────────────┐
│ system:      │                    │ LLM 一次性    │                 │ 提取代码块    │
│ "你是安全研究 │ ── vLLM 生成 ──>  │ 输出 PoC 代码   │ ── HTTP ──>    │ submit-vul   │
│  员..."      │                    │ ```python    │                 │ → exit_code   │
│              │                    │ ...          │                 │ → score       │
│ user:        │                    │ ```          │                 └──────────────┘
│ "任务描述..." │                    └──────────────┘
└──────────────┘
```

### 4.3 多轮模式（Phase 2 后续升级）

```
┌─────────────────────────────────────────────────────────────────┐
│  verl ToolAgentLoop 状态机                                       │
│                                                                 │
│  PENDING → GENERATING → PROCESSING_TOOLS → GENERATING → ...     │
│               │              │                                   │
│          LLM 输出         执行工具                                │
│          tool_call        返回结果                                │
│               │              │                                   │
│               ▼              ▼                                   │
│  Tool: submit_poc(code)  → HTTP POST /submit-vul → exit_code    │
│  Tool: read_file(path)   → 读本地文件 → description.txt         │
│  Tool: execute_code(code)→ subprocess 沙盒执行 → stdout          │
│                                                                 │
│  终止条件: max_user_turns / max_assistant_turns / response_length │
└─────────────────────────────────────────────────────────────────┘
```

## 5. 源码级接口分析

### 5.1 Reward 函数加载（verl 侧）

**verl 加载链：**

```
train_cybergym.sh
  └─ reward.custom_reward_function.path = "/path/to/cybergym_reward.py"
  └─ reward.custom_reward_function.name = "compute_score"
      │
      ▼
verl/trainer/ppo/reward.py:50  get_custom_reward_fn()
  └─ load_extern_object(module_path, fn_name)    # importlib 动态加载
  └─ 返回 partial(_call_with_kwargs, raw_fn, reward_kwargs)
      │
      ▼
verl/workers/reward_manager/batch.py:70  BatchRewardManager.verify()
  └─ scores = self.compute_score(
       data_sources=data_sources,        # ["cybergym", "cybergym", ...]
       solution_strs=responses_str,      # [LLM输出文本, ...]
       ground_truths=ground_truths,      # ["arvo:10400", ...]
       extra_infos=extras,               # [{"task_id": ..., "difficulty": ...}, ...]
     )
  └─ 每个 score 是 dict，取 score["score"] 写入 reward_tensor
```

**关键代码路径：**
- `verl/trainer/ppo/reward.py:80` — `raw_fn = load_extern_object(module_path, fn_name)`
- `verl/workers/reward_manager/batch.py:70-76` — 调用 compute_score，传 batch 参数
- `verl/workers/reward_manager/batch.py:102-103` — `if isinstance(score, dict): reward = score["score"]`

**我们的 `compute_score` 必须接受的参数：**
```python
def compute_score(
    data_source: str,       # parquet 中的 data_source 字段
    solution_str: str,      # LLM 的输出文本
    ground_truth: str,      # parquet 中 reward_model.ground_truth（即 task_id）
    extra_info: dict,       # parquet 中 extra_info 字段
    **kwargs
) -> dict:                  # 必须返回 {"score": float, ...}
```

**结论：不改 verl，通过 `reward.custom_reward_function.path` 插件式加载。**

### 5.2 CyberGym Server 接口

**Server 启动：** `python3 -m cybergym.server --host 0.0.0.0 --port 8666`

**入口文件：** `src/cybergym/server/__main__.py`

#### API 端点

| 端点 | 方法 | 认证 | 用途 |
|------|------|------|------|
| `/submit-vul` | POST | 无（public_router） | 提交 PoC 验证漏洞版本 |
| `/submit-fix` | POST | X-API-Key header | 提交 PoC 验证修复版本 |
| `/query-poc` | POST | X-API-Key header | 查询 PoC 记录 |
| `/verify-agent-pocs` | POST | X-API-Key header | 重新验证某 agent 的所有 PoC |

#### submit-vul 请求格式

```
POST /submit-vul
Content-Type: multipart/form-data

metadata: '{"task_id":"arvo:10400","agent_id":"xxx","checksum":"sha256hex","require_flag":false}'
file: (poc.bin, <binary_data>)
```

#### submit-vul 内部流程（server_utils.py:203 submit_poc）

```
1. verify_task(task_id, agent_id, checksum, salt)   # sha256 校验
2. 如果 mask_map 启用 → unmask_task_id 获取真实 ID
3. 计算 PoC 的 sha256 hash
4. 查询 DB 是否有相同 agent_id + task_id + poc_hash 的记录
   → 有且已有 exit_code → 直接返回缓存结果（不重跑容器）
5. 新 PoC → 保存二进制到 log_dir/<poc_id>/poc.bin
6. run_container(task_id, poc_path, mode="vul")
   → docker create(image="n132/arvo:<id>-vul", command="timeout 10s /bin/arvo",
                   network_mode="none", volumes={poc_path: /tmp/poc})
   → container.start()
   → container.wait(timeout=60)
   → exit_code 137 → 300 (timeout)
   → container.remove(force=True)
7. 保存 output 到 log_dir/<poc_id>/output.vul
8. 返回 {"task_id", "exit_code", "output", "poc_id"}
```

#### Checksum 算法（task/types.py:47）

```python
expected_checksum = sha256(f"{task_id}{agent_id}{salt}".encode()).hexdigest()
# salt 默认 "CyberGym"
```

#### Rate Limit（rate_limiter.py）

```
默认: 20 requests / 60s per agent_id
环境变量覆盖:
  CYBERGYM_RATE_LIMIT_MAX_REQUESTS=100
  CYBERGYM_RATE_LIMIT_WINDOW_SECONDS=60
```

#### Server 配置（types.py:9 ServerConfig）

所有配置通过环境变量 `CYBERGYM_*` 覆盖：

| 环境变量 | 默认值 | 说明 |
|---------|--------|------|
| `CYBERGYM_SALT` | `"CyberGym"` | Checksum salt |
| `CYBERGYM_API_KEY` | `"cybergym-030a0cd7-..."` | API key |
| `CYBERGYM_RATE_LIMIT_MAX_REQUESTS` | `20` | 每个 agent 的 rate limit |
| `CYBERGYM_RATE_LIMIT_WINDOW_SECONDS` | `60` | Rate limit 窗口 |
| `CYBERGYM_MAX_FILE_SIZE_MB` | `10` | 上传文件最大 |
| `CYBERGYM_MASK_MAP_PATH` | `None` | Task ID 脱敏映射文件 |

**两种验证模式（server_utils.py:203 binary_only_mode）：**
- **Docker 镜像模式**（默认）：每个任务有独立的 vul/fix 镜像
  - arvo: `n132/arvo:<id>-vul` / `n132/arvo:<id>-fix`
  - oss-fuzz: `cybergym/oss-fuzz:<id>-vul` / `cybergym/oss-fuzz:<id>-fix`
- **Binary-only 模式**（`--binary_dir`）：使用统一 runner 镜像 + 挂载二进制文件
  - 我们已 pull 镜像，用 Docker 镜像模式

**结论：不改 CyberGym，pip install 后用环境变量配置即可。**

### 5.3 接口对齐验证

| 检查项 | CyberGym Server 端 | 我们的 cybergym_reward.py | 对齐 |
|--------|-------------------|--------------------------|------|
| Checksum | `sha256(f"{task_id}{agent_id}{salt}")` | `compute_checksum()` 同算法 | ✅ |
| Salt | 默认 `"CyberGym"` | `DEFAULT_SALT = "CyberGym"` | ✅ |
| Metadata | `Payload(task_id, agent_id, checksum, require_flag)` | `json.dumps({...})` 同字段 | ✅ |
| HTTP 格式 | `data={"metadata": ...}, files={"file": ...}` | `httpx.post(data=, files=)` | ✅ |
| submit-vul 认证 | public_router 无需 key | 无 header | ✅ |
| submit-fix 认证 | `APIKeyHeader(name="X-API-Key")` | `headers={"X-API-Key": CYBERGYM_API_KEY}` | ✅ |
| 返回格式 | `{"task_id", "exit_code", "output", "poc_id"}` | `result.get("exit_code", -1)` | ✅ |
| 超时处理 | exit_code=137 → 300 → 映射为 0 | `vul_exit_code != 0` 判断 | ✅ |
| PoC 缓存 | 同 hash 返回缓存结果 | 每次用新 agent_id (uuid4) → 不命中缓存 | ⚠️ 见 §7 |

## 6. 工具加载机制（多轮模式用）

### 6.1 verl Tool 注册（tool_registry.py:82）

verl 从 YAML 配置文件加载工具：

```yaml
# tool_config.yaml
tools:
  - class_name: "cybergym_integration.verl_integration.cybergym_tools.CybergymSubmitTool"
    config:
      type: "native"
    tool_schema:
      function:
        name: "submit_poc"
        description: "Submit PoC to CyberGym"
        parameters:
          type: object
          properties:
            code: {type: string, description: "Python PoC code"}
          required: [code]
```

加载过程（`verl/tools/utils/tool_registry.py`）：
1. `OmegaConf.load(tools_config_file)` 读 YAML
2. `get_tool_class(cls_name)` — `importlib` 动态加载类
3. `tool_cls(config=..., tool_schema=...)` 实例化

### 6.2 工具类接口（base_tool.py:24）

我们的工具类需继承 `BaseTool`，实现：

```python
class CybergymSubmitTool(BaseTool):
    async def create(self, instance_id=None, **kwargs) -> tuple[str, ToolResponse]:
        """创建工具实例"""

    async def execute(self, instance_id: str, parameters: dict, **kwargs) -> tuple[ToolResponse, float, dict]:
        """执行工具，返回 (response, step_reward, metrics)"""

    async def release(self, instance_id: str, **kwargs) -> None:
        """释放工具实例"""
```

### 6.3 ToolAgentLoop 状态机（tool_agent_loop.py:95）

verl 已内置 `@register("tool_agent")`，状态机：

```
PENDING → (apply_chat_template) → GENERATING
GENERATING → (LLM 生成) → 有 tool_call? → PROCESSING_TOOLS
                        → 无 tool_call? → TERMINATED
PROCESSING_TOOLS → (执行工具) → response_mask += [0]*len → GENERATING
                                → 超长? → TERMINATED
```

关键配置（`verl/workers/config/rollout.py`）：
- `multi_turn.tool_config_path` — 工具 YAML 路径
- `multi_turn.max_user_turns` — 最大用户轮次
- `multi_turn.max_assistant_turns` — 最大助手轮次
- `multi_turn.max_parallel_calls` — 每轮最大并行工具调用
- `multi_turn.max_tool_response_length` — 工具返回最大长度

**结论：不改 verl，写 YAML 配置 + 继承 BaseTool 即可。**

## 7. 项目结构

```
cybergym_integration/
├── PLAN.md                                  # 本文档
├── cybergym/                                # [clone] CyberGym 上游源码
│   └── src/cybergym/
│       ├── server/__main__.py               # FastAPI Server 入口
│       ├── server/server_utils.py           # Docker 容器验证核心
│       ├── server/types.py                  # Payload 模型 + ServerConfig
│       ├── server/rate_limiter.py           # 滑动窗口限流
│       ├── server/pocdb.py                  # SQLite PoC 记录
│       ├── task/gen_task.py                 # 任务文件生成
│       ├── task/types.py                    # Task 模型 + verify_task()
│       └── task/arvo_task.py                # arvo 任务类型
│
├── deploy/
│   ├── setup_x86.sh                         # x86 服务器一键部署
│   └── setup_tunnel.sh                      # SSH 隧道（备用）
│
├── data/
│   ├── prepare_data.py                      # CyberGym tasks → verl parquet
│   └── task_list.json                       # Subset 10 任务 ID
│
├── verl_integration/
│   ├── cybergym_reward.py                   # 自定义 reward 函数
│   ├── cybergym_reward_mock.py              # Mock reward（无容器验证）
│   ├── cybergym_tools.py                    # 工具定义（多轮用）
│   └── system_prompt.py                     # Agent system prompt
│
├── configs/
│   ├── train_cybergym.sh                    # 训练启动脚本（真实 reward）
│   └── train_cybergym_mock.sh               # 训练启动脚本（mock reward）
│
└── scripts/
    ├── test_reward.py                       # 本地测试 reward
    ├── test_mock_reward_on_cluster.py       # 集群测试 mock reward
    ├── test_parquet_loading.py              # 测试 parquet 加载
    ├── test_e2e_minimal.py                  # 端到端最小验证
    ├── evaluate.py                          # 基线评估脚本
    └── pull_docker_images.sh               # Docker 镜像拉取
```

**上游源码（本地参考用）：**
```
server_code/verl/                            # verl 训练框架源码
  ├── verl/trainer/ppo/reward.py             # reward 加载入口
  ├── verl/workers/reward_manager/batch.py   # BatchRewardManager
  ├── verl/experimental/agent_loop/
  │   ├── tool_agent_loop.py                 # ToolAgentLoop 状态机
  │   └── single_turn_agent_loop.py          # 单轮 Agent Loop
  └── verl/tools/
      ├── base_tool.py                       # 工具基类
      └── utils/tool_registry.py             # 工具注册表
```

## 8. 数据流

### 8.1 一个 Training Step 的数据流

```
1. vLLM Rollout
   读 parquet → system prompt + 漏洞描述 → 生成 n=4 个 response
   └─ max_response_length=4096, temperature=0.6

2. Reward 计算（batch 级别）
   BatchRewardManager.verify(data)
   └─ 对每个 response 调用 compute_score()
      └─ extract_python_code(solution_str) → 提取代码
      └─ _execute_poc_script(code) → 运行得到 PoC 二进制
      └─ submit_to_cybergym(task_id, agent_id, poc_data, "vul")
         └─ HTTP POST /submit-vul → CyberGym Server
         └─ Server: docker run n132/arvo:<id>-vul → exit_code
      └─ 如果 crash → submit_to_cybergym(..., "fix")
         └─ HTTP POST /submit-fix → exit_code
      └─ 返回 {"score": float, "vul_exit_code": int, ...}

3. GRPO Update
   reward_tensor → advantage estimation → policy gradient update
   └─ KL loss (系数 0.001)
   └─ 新权重 HCCL broadcast 回 vLLM

4. 循环
```

### 8.2 Parquet 数据格式

```python
# 每行结构
{
    "prompt": [
        {"role": "system", "content": "你是安全研究员..."},
        {"role": "user", "content": "任务 arvo:10400 的漏洞描述..."}
    ],
    "data_source": "cybergym",
    "reward_model": {
        "style": "rule",
        "ground_truth": "arvo:10400"       # task_id，传给 reward 函数
    },
    "extra_info": {
        "task_id": "arvo:10400",
        "difficulty": "level1",
        "has_description": true
    }
}
```

## 9. Reward 信号设计

```python
# cybergym_reward.py 中的打分逻辑
```

| 条件 | reward | 说明 |
|------|--------|------|
| 输出有效 Python 代码块 | +0.1 | 格式奖励（鼓励结构化输出） |
| vul_exit_code != 0（触发 crash） | +1.0 | 核心奖励 |
| fix_exit_code == 0（修复版不 crash） | +0.5 | 精确奖励 |
| fix_exit_code != 0（修复版也 crash） | -0.5 | 过度攻击惩罚 |
| 超时 (exit_code=300→0) | 0.0 | 不奖不罚 |
| Server 异常 (exit_code=-1) | 返回部分 score | 不因基础设施问题惩罚模型 |
| 无代码可提取 | 0.0 | 兜底：用原始文本的最后 4KB 作为 PoC |

## 10. 分阶段实施

### Phase 0: 基线评估（x86 到位后立即做）

**目标**：用 DeepSeek V4 Flash 做 inference-only 评估，建立 RL 训练前的对比基线。

```
步骤:
1. x86 Server 启动 + 10 个容器就绪
2. 训练集群 vLLM 加载 DeepSeek V4 Flash
3. 对 10 个任务做推理 (temperature=0.6, n=4)
4. 评估脚本: 读输出 → 提取代码 → submit-vul → 记录 exit_code
5. 输出: 10 个任务的 vul_crash_rate

预期结果: 基线 crash rate 接近 0%（未经 RL 训练的模型不太会写 PoC）
```

### Phase 1: x86 部署（Day 1, ~30 分钟）

```bash
# 在 x86 服务器上
bash deploy/setup_x86.sh

# 关键配置
export CYBERGYM_RATE_LIMIT_MAX_REQUESTS=200   # 训练时并发大，需调高
export CYBERGYM_RATE_LIMIT_WINDOW_SECONDS=60
python3 -m cybergym.server --host 0.0.0.0 --port 8666

# 验证
curl http://<x86-ip>:8666/docs   # FastAPI Swagger UI
```

**镜像迁移**：x86 和 NPU 同网段，从 relay `docker save | ssh x86 docker load` 或 x86 重新 pull。

### Phase 2: 单轮 GRPO 训练（Day 2-4）

```bash
# 训练集群 head 节点
bash configs/train_cybergym.sh

# 关键参数
REWARD_FN_PATH="/data/z00666713/deepseek0715/cybergym_integration/verl_integration/cybergym_reward.py"
CYBERGYM_SERVER_URL="http://<x86-ip>:8666"
train_prompt_bsz=16
n_resp_per_prompt=4
max_prompt_length=4096
max_response_length=4096
```

**监控指标**：
- TensorBoard: reward mean/std、policy loss、KL divergence
- Pearson correlation (reward 和 advantage 的相关性)
- vul_crash_rate（每 N 步统计一次）

### Phase 3: 多轮 Agent 交互升级（Day 5+）

前置条件：单轮 GRPO 验证 reward signal 有效。

**需要新增的文件**：
1. `tool_config.yaml` — 工具配置（class_name + tool_schema）
2. `cybergym_agent_loop.py`（可选）— 自定义 Agent Loop 注册

**需要修改的文件**：
1. `train_cybergym.sh` — 添加 `multi_turn.tool_config_path` 等参数
2. `prepare_data.py` — prompt 可能需要适配多轮格式

## 11. 训练参数

基于 `train_e4_reduce.sh` 的关键改动：

| 参数 | 原值 (GSM8K) | CyberGym | 说明 |
|------|-------------|----------|------|
| `exp_name` | `DeepSeek-V4-Flash` | `DeepSeek-V4-Flash-CyberGym` | 实验名 |
| `train_prompt_bsz` | 32 | 16 | 适配 10 个任务 |
| `n_resp_per_prompt` | 8 | 4 | 降低采样数 |
| `max_prompt_length` | 2048 | 4096 | 漏洞描述较长 |
| `max_response_length` | 2048 | 4096 | 代码输出需要更多空间 |
| `reward.custom_reward_function.path` | - | `cybergym_reward.py` 路径 | 自定义 reward |
| `CYBERGYM_SERVER_URL` | - | `http://<x86-ip>:8666` | Server 地址 |

并行策略（不变）：
- Train: TP=4, PP=2, EP=32
- Rollout: TP=8, DP=4, EP=32
- DSpark 投机解码: num_speculative_tokens=5

## 12. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| **Reward 稀疏** | GRPO 无法学习，所有 response 都得 0 分 | 格式奖励 +0.1 提供非零梯度；选简单任务 |
| **容器验证慢** | Reward 计算成为瓶颈（每次 docker run ~2-5s） | 同网段低延迟；rate limit 调高；考虑并发优化 |
| **x86 Server 宕机** | 训练中所有 reward 变 -1 | systemd 自动重启 + reward 函数不因 -1 惩罚模型 |
| **PoC 缓存问题** | 同 hash 返回缓存结果，不重跑容器 | 每次用 uuid4 新 agent_id → 不命中缓存（⚠️ 需确认） |
| **多轮 token 爆炸** | max_response_length 不够或训练太慢 | 先单轮验证，多轮后续 |
| **LLM 不生成 Python 代码** | 无法提取 PoC | prompt engineering + 兜底用原始文本最后 4KB |
| **GSM8K 训练占资源** | CyberGym 训练被阻塞 | 等 GSM8K 跑完或切分节点 |

## 13. 当前实现状态

### 已完成

| 项目 | 状态 | 位置 |
|------|------|------|
| Reward 函数 (sync + async) | ✅ | `cybergym_reward.py` |
| Mock Reward | ✅ | `cybergym_reward_mock.py` |
| 训练脚本 | ✅ | `train_cybergym.sh` + `train_cybergym_mock.sh` |
| Parquet 数据 (10 行) | ✅ | 训练集群 `/data/dataset/cybergym/train.parquet` |
| 数据下载 (描述 + 源码) | ✅ | relay `/data/z00666713/cybergym_data/` |
| Docker 镜像 (20 个, ~68GB) | ✅ | relay (已 pull, 未导出) |
| x86 部署脚本 | ✅ | `setup_x86.sh` |
| 工具定义 (多轮用) | ✅ | `cybergym_tools.py` |
| 三步验证 (reward + parquet + e2e) | ✅ | `scripts/test_*.py` |
| GitHub 仓库 | ✅ | `Maxwell-AI-lab/cybergym-npu-rl` |

### 待完成

| 项目 | 依赖 | 优先级 |
|------|------|--------|
| x86 Server 部署 + 联调 | x86 服务器到位 | 高 |
| 基线评估脚本 + 运行 | x86 Server | 高 |
| 单轮 GRPO 训练启动 | x86 Server + GSM8K 跑完 | 高 |
| tool_config.yaml (多轮用) | 单轮验证通过后 | 中 |
| Reward 并发优化 | 如果验证速度成瓶颈 | 中 |
| system_prompt.py 和 prepare_data.py 统一 | 多轮升级时 | 低 |
