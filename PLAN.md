# OpenCode + CyberGym + VERL 后训练集成方案

> **黑盒轨迹捕获 · 三级容器编排 · 全异步训练架构**
> v2.0 · 2026-08-21 · 基于飞书方案对齐 + opencode Agent 对接

---

## 0. 当前实现状态（快速索引）

| 阶段 | 状态 | 说明 |
|------|------|------|
| **单轮 GRPO 训练** | ✅ v12 跑通 | step:1 零错误，main_ppo 正常退出，轨迹质量正常 |
| **x86 CyberGym Server** | ✅ 部署完成 | 192.168.0.100:8666，23/23 联调通过，延迟 0.19s |
| **12 节点 910B 集群** | ✅ 稳定运行 | weight sync / master_param / OOM / checkpoint 四大 crash 全部修复 |
| **opencode Agent 对接** | 🔄 进行中 | x86 容器已起，等 DEEPSEEK_API_KEY 完成配置 |
| **trajproxy 轨迹捕获** | ⏸ 方案设计 | 飞书方案核心组件，需评估部署方式 |
| **全异步训练** | ⏸ 方案设计 | VERL Fully Async Trainer 原生支持，待单轮稳定后升级 |

---

## 1. 项目目标

### 1.1 背景：为什么要做 CyberGym 后训练

**CyberGym** 是 UC Berkeley Sunblaze Lab 发布的安全漏洞分析 benchmark（ICLR 2026）：
- 1507 个真实漏洞，188 个开源项目，数据源于 Google OSS-Fuzz
- 任务：给定有漏洞的 C/C++ 源码，Agent 阅读源码 → 定位漏洞 → 构造 PoC 使程序崩溃
- 验证：PoC 在 pre-patch 和 post-patch 双容器运行，vul crash AND fix 不 crash 才算成功
- 难度分级：level0（纯逆向）→ level1（+描述）→ level2（+crash 输出）→ level3（+修复代码+patch）

**为什么要做后训练**：
- 基础大模型在安全漏洞分析上表现不佳，level0 纯逆向成功率不足 5%
- SFT 只能注入有限安全知识，无法覆盖多样化漏洞模式
- 需要通过 RL 后训练，让模型在与环境交互中自主学习漏洞挖掘策略
- 业界标杆：顶尖 Agent 系统在 CyberGym 上已达 90%+ 成功率

**本方案目标**：从 AI Infra 视角，设计并实现 CyberGym 漏洞分析任务在 VERL 体系上的端到端后训练方案，跑通从数据采样到策略更新的完整闭环。

### 1.2 目标与边界

- **目标**：跑通端到端训练闭环，验证 RL 后训练在漏洞分析任务上的有效性
- **边界**：不绑定具体 RL 算法（PPO/GRPO 可切换）；不涉及数据管线建设；聚焦工程落地
- **技术选型**：VERL + Ascend AgentSDK/Aura + trajproxy + OpenCode + CyberGym + SEGym

## 2. 硬件资源

| 角色 | 机器 | 规格 | 用途 |
|------|------|------|------|
| 训练集群 | 12x Ascend 910B (aarch64) | 96 NPUs | VERL 训练 (64 NPU) + vLLM 推理 (32 NPU) |
| x86 服务器 | 192.168.0.100 | 32C/64GB | CyberGym Server + OpenCode Agent 容器 |
| 跳板 | Relay (119.8.234.170) | - | SSH 隧道 + 数据中转 |

**节点分布**：

| 角色 | IP (192.168.0.x) | NPU 数 |
|------|------|------|
| Head | .36 | 8 |
| Train | .41 .51 .88 .89 .189 .47 .50 | 7×8=56 |
| Rollout | .17 .195 .85 .48 | 4×8=32 |

## 3. 挑战：五大因果链

飞书方案梳理了一条从任务本质到工程落地的因果链：

```
根源 · 任务本质          衍生 · 算法困境         选择 · Agent 方案
长上下文 + 多轮交互  →   稀疏二值奖励       →   黑盒轨迹捕获
5K-50K tokens 源码      PoC 只有 crash/不crash    OpenCode autoCompact
25-50 轮交互            训练初期成功率<5%          动态 Prompt
100K-500K tokens/rollout GRPO group 全0 停滞       工具调用序列化
        ↓                       ↓                       ↓
约束 · 验证方式         落地 · 工程规模
高延迟评估             多容器生命周期管理
单条 30-60s            3 类容器（Agent + vul + fix）
batch=192 齐等         network=none 隔离
NPU 利用率<30%         物理分池防逃逸
```

**量化影响**：
- 稀疏奖励：有效 group 占比 <10%，90%+ 训练 step 无梯度更新
- 黑盒轨迹：不做精确捕获导致训推不一致，MemOPD p99 logprob 误差 1.774
- 高延迟评估：CyberGym 评估耗时是 SWE-Bench 的 4.5 倍（30-60s vs ~10s）
- 长上下文：CTF 任务实测单次 20M-58M tokens

## 4. 整体架构

### 4.1 组件逻辑关系（飞书方案完整版）

```
NPU 集群 · 训练与推理            Agent 编排 · 轨迹捕获           Agent 沙箱 · CPU 节点
┌─────────────────────┐    ┌──────────────────────────┐   ┌─────────────────────────┐
│ VERL Trainer        │    │ trajproxy               │   │ OpenCode Agent 容器      │
│ PPO/GRPO 策略更新    │    │ OpenAI 兼容代理          │   │ 读源码→分析→构造PoC      │
│ 全异步消费经验队列   │    │ 记录 token_ids+logprobs  │   │ bash/read/write 工具     │
│                     │    │ 按 trial_id 隔离会话      │   │ 写入 /app/poc            │
│ NPU 推理服务        │◄──►│ 前缀匹配缓存            │◄─►│ max_turns=15             │
│ vLLM/MindSpeed      │    │ Token-in-Token-out 模式   │   │ 关闭 autoCompact         │
│ 前缀缓存+动态batch   │    └──────────────────────────┘   └──────────┬──────────────┘
└──────────┬──────────┘              ▲                                │
           │ 权重同步                 │ 轨迹回传                       │ Get_Files 读 PoC
           │                         │                                ▼
┌──────────┴──────────┐    ┌─────────┴──────────┐    ┌─────────────────────────────┐
│ Ascend AgentSDK      │    │ TransferQueue      │    │ CyberGym Server :8666       │
│ CyberGymEnv          │    │ 经验队列 (Ray)      │    │ SQLite 哈希去重              │
│ BaseAgent/BaseEnv    │    │ 按 group 组织       │    │ 调度 vul+fix 双容器          │
│ 统一抽象层           │    │ 优先级+去重         │    │ Squid 防火墙                │
└─────────────────────┘    └────────────────────┘    │                             │
                                                      │ vul容器     fix容器          │
                                                      │ pre-patch   post-patch       │
                                                      │ network=none network=none    │
                                                      └─────────────────────────────┘
```

### 4.2 当前已实现架构（Phase 1 单轮模式）

```
训练集群 (910B, 192.168.0.x)                    x86 服务器 (.100)
┌──────────────┐  HCCL broadcast  ┌────────────┐   ┌──────────────────┐
│  8 Train 节点 │ ───────────────> │ 4 Rollout  │   │ CyberGym Server  │
│  (Megatron)  │   weight sync    │ (vLLM)     │   │ (FastAPI :8666)  │
│  GRPO update │                  │            │──>│ Docker × 18     │
└──────────────┘                  └─────┬──────┘   │ (9 vul + 9 fix) │
                                        │          └────────┬─────────┘
                              reward HTTP POST               │
                              /submit-vul                    │
                                        │                    │
                                        ▼                    │
                              ┌──────────────────┐           │
                              │ cybergym_reward  │  docker run│
                              │ .py              │  容器验证   │
                              │ (custom reward)  │◄──────────┘
                              └──────────────────┘  exit_code
```

### 4.3 目标架构（Phase 2+ 多轮 opencode Agent 模式）

```
训练集群 (910B)                              x86 服务器 (.100)
┌────────────────┐                        ┌─────────────────────────────┐
│ vLLM (rollout) │ ──推理请求──>           │  trajproxy (可选)            │
│                │                         │  记录 token_ids + logprobs   │
│ tool_agent_loop│                         │  转发到 vLLM                 │
│  (verl)        │                         └──────────┬──────────────────┘
│                │                                     │
│                │ ──工具调用──>                        │
│                │                         ┌───────────▼──────────────────┐
│                │                         │  OpenCode Agent 容器          │
│                │ <──工具返回──           │  读源码→分析→构造PoC           │
│                │                         │  写 /app/poc                  │
│                │                         └───────────┬──────────────────┘
│                │                                     │ PoC 提交
│                │                                     ▼
│ cybergym_reward│                         ┌──────────────────────────────┐
│ (custom reward)│ <── reward ──           │  CyberGym Server :8666       │
└────────────────┘                         │  vul+fix 双容器验证           │
                                           └──────────────────────────────┘
```

## 5. 核心组件详解

### 5.1 trajproxy：黑盒 Agent 轨迹捕获

**核心问题**：OpenCode 是黑盒 Agent，其 autoCompact、动态 Prompt、工具调用序列化等机制对训练侧隐藏真实状态，而 Policy Gradient 必须精确重算每个 token 的 logprob。

**解决方案**：trajproxy 作为 LLM 透明代理，拦截 OpenCode 的所有 LLM 调用。

**双模式处理**：
- **直接转发模式**（调试/评估）：仅记录请求/响应文本，延迟最低
- **Token-in-Token-out 模式**（训练用）：记录完整 token_ids + per-token logprobs，支持前缀匹配缓存

**关键能力**：
- 工具调用解析：原生支持 DeepSeek / Qwen / Hermes 等格式
- 动态模型管理：运行时注册/删除模型，支持训练中策略热更新
- 多 Worker 分布式：Ray 原生支持，水平扩展
- 保真度 >0.99

**我们需要做的**：配置 trial_id 路由规则 + 实现轨迹数据到 VERL 格式的转换适配器。

### 5.2 Ascend AgentSDK (Aura)：VERL 之上的统一抽象层

**定位**：Agentic RL 训推调一体化框架，兼容多种训练引擎，原生支持昇腾 NPU。

**三大基类**：

| 基类 | 用途 | CyberGym 实现 |
|------|------|---------------|
| BaseAgent | Agent 与环境交互的标准接口 | 复用 OpenCode 作为 Agent |
| BaseEnv（核心） | 任务初始化、step、reward | CyberGymEnv (~500行) |
| BaseEngineWrapper | 推理引擎封装 | OpenCodeEngineWrapper (~200行) |

**Phase 1 实现清单**：
1. **CyberGymEnv** (~500行)：gen_task / step / reset / get_reward 四个接口
2. **OpenCodeEngineWrapper** (~200行)：封装 LLM 调用，OPENAI_BASE_URL 指向 trajproxy
3. **TrajectoryConverter** (~150行)：trajproxy 轨迹 → VERL token_ids + logprobs 格式
4. **cybergym_grpo.yaml**：模型/数据集/算法/Agent/Reward 全部参数

### 5.3 SEGym：容器生命周期管理

**五大能力域**：池化调度 / 生命周期操作 / 健康与容错 / 资源隔离 / 可观测性

**三级容器池化架构**：

| 级别 | 部署位置 | 镜像 | 池配置 | 资源 |
|------|---------|------|--------|------|
| **OpenCode 运行池** | CPU 节点池 A | opencode-cybergym | min_idle=8, max=256 | 2 CPU / 4GB |
| **CyberGym 验证池** | CPU 节点池 B (物理隔离) | cybergym-validator | min_idle=16, max=128 | 1 CPU / 512MB, network=none |
| **NPU 训推池** | NPU 节点 (910B) | VERL + vLLM | 3D 并行 + ZeRO | max_model_len=128K |

**容器池化六项优化**：
1. 镜像分层缓存：拉取 30s→2s
2. 常驻容器池：消除 create+start 开销
3. 弹性扩缩容：利用率提升 40%
4. 异常自愈：心跳检测 + 超时 kill + 孤儿清理
5. 物理隔离安全：验证容器与 Agent 容器分节点
6. 资源超卖控制：CPU 1.5x 超卖，内存不超卖

### 5.4 OpenCode Agent 运行时

**部署位置**：x86 服务器 Docker 容器（当前 192.168.0.100）

**核心配置**：
- `max_turns=15`（限制多轮交互轮数）
- `autoCompact=OFF`（关闭自动压缩，保留完整轨迹）
- `OPENAI_BASE_URL` 指向 trajproxy（训练模式）或 deepseek API（评估模式）
- 工具：bash / read / write（容器内可用）
- 输出写入 `/app/poc`

**LLM Provider 选择**：
- **评估/调试模式**：直接调 `api.deepseek.com`（deepseek-v4-flash），需 DEEPSEEK_API_KEY
- **训练模式**：经 trajproxy 转发到集群 vLLM（策略模型），记录 token 级 logprob

### 5.5 CyberGym 本地验证服务

**Server 配置**：本地 Python 进程 :8666，SQLite 哈希去重

**验证流程**：
```
OpenCode 生成 PoC → 写入 /app/poc → Harness 读 PoC → HTTP POST 到 Server
  → Server 查缓存 → 调度 vul 容器(pre-patch) + fix 容器(post-patch)
  → 返回 {vul_exit_code, fix_exit_code, output, poc_id}
```

**自带防火墙**：
- `cybergym.firewall`：Squid 代理 + 域名白名单
- `cybergym-internal`：隔离 Docker 网络，无外网路由
- Agent 容器跑在该网络上，出站流量走 Squid

## 6. 奖励计算

### 6.1 完整双验证模式（评估用）

| 场景 | reward | 标记 | 说明 |
|------|--------|------|------|
| vul crash + fix 不 crash | **1.0** | success | 真正触发了目标漏洞 |
| vul crash + fix 也 crash | 0.0 | wrong_bug | 触发的不是目标漏洞 |
| vul 不 crash | 0.0 | fail | PoC 无效 |
| Agent 未生成 PoC / Server 超时 | 0.0 | infra_error | 基础设施问题 |

### 6.2 训练优化模式（Phase 1/2 推荐）

只跑 vul 容器，`vul_exit_code != 0` 即给 `reward=1.0`。

- **优势**：验证延迟从 ~60s 降到 ~30s，正样本率翻倍
- **代价**：可能学到触发非目标 bug 的策略
- **适用**：训练初期成功率极低，代价可接受

### 6.3 当前已实现的 reward 函数

`cybergym_reward.py` 中的 `compute_score()` 已实现：
- 从 LLM 输出提取 Python 代码块
- 执行代码得到 PoC 二进制
- HTTP POST 到 CyberGym `/submit-vul` → exit_code
- crash 时追加 `/submit-fix` 验证
- 返回 `{"score": float, "vul_exit_code": int, "fix_exit_code": int, ...}`

## 7. 全异步训练架构

### 7.1 同步模式的问题

- 单条 rollout 耗时 5-20 分钟（Agent 执行 + PoC 验证）
- 同步模式必须等整批 192 条全部返回才能更新
- NPU 大部分时间在空等，利用率不足 30%
- 按 batch=192、平均 10min 计算：1 step ≈ 2.5 小时

### 7.2 全异步模式（推荐）

```
Rollout Worker 池 (32 并发)          TransferQueue              PPO/GRPO Trainer
┌───────────────────────┐         ┌─────────────────┐        ┌──────────────────┐
│ OpenCode 执行          │ ──入队─>│ 经验队列 (Ray)   │──消费─>│ 队列有数据就更新   │
│ trajproxy 轨迹捕获     │         │ 按 group 组织    │        │ mini-batch 梯度累积│
│ CyberGym 验证 + reward │         │ 优先级 + 去重    │        │ 异步同步最新权重   │
└───────────────────────┘         └─────────────────┘        └──────────────────┘
```

**关键超参**：`train_batch=64, mini_batch=8, ppo_epochs=1, max_staleness=2, rollout_workers=32`

**核心权衡**：
- Policy staleness：rollout 和 train 策略有差异，`max_staleness=2` + VERL rollout correction
- ARPO Replay Buffer：注入成功轨迹，解决稀疏奖励
- Group 过滤：全 0 或全 1 的 group 直接丢弃，只训有差异的样本

### 7.3 当前状态

**Phase 1（已完成）**：同步模式单轮 GRPO，v12 跑通 step:1。验证 reward signal 有效。

**Phase 2 目标**：多轮 opencode Agent + 异步训练，NPU 利用率从 30% 提升到 70%+。

## 8. 端到端调用链路（一次 rollout 的 9 步）

```
① VERL Trainer 发起 rollout，策略权重同步到 NPU 推理集群
② AgentSDK CyberGymEnv 通过 SEGym 启动 OpenCode 容器，上传任务文件
③ SEGym Container Manager 从池中分配容器，管理生命周期
④ OpenCode 多轮交互：读源码 → 分析漏洞 → 构造 PoC → 写 /app/poc
⑤ 每次 LLM 调用经过 trajproxy，透明转发到 NPU 并记录 token_ids + logprobs
⑥ AgentSDK 通过 SEGym Get_Files 读取容器内 /app/poc
⑦ HTTP POST PoC 到 CyberGym Server (:8666)，调度 vul/fix 双容器验证
⑧ reward 判定：vul crash AND fix 不 crash → reward=1.0
⑨ trajproxy 轨迹 + reward 打包写入 TransferQueue，Trainer 异步消费更新权重
```

## 9. 源码级接口分析

### 9.1 Reward 函数加载（verl 侧）

```
train_cybergym.sh
  └─ reward.custom_reward_function.path → cybergym_reward.py
  └─ reward.custom_reward_function.name → "compute_score"
      │
      ▼
verl/trainer/ppo/reward.py:50  get_custom_reward_fn()
  └─ load_extern_object(module_path, fn_name)
      │
      ▼
verl/workers/reward_manager/batch.py:70  BatchRewardManager.verify()
  └─ compute_score(data_source, solution_str, ground_truth, extra_info)
  └─ score["score"] → reward_tensor
```

**结论：不改 verl，通过 `reward.custom_reward_function.path` 插件式加载。**

### 9.2 工具加载机制（多轮模式用）

verl 从 YAML 配置文件加载工具：

```yaml
# tool_config.yaml
tools:
  - class_name: "...CybergmSubmitTool"
    config: { type: "native" }
    tool_schema: { function: { name: "submit_poc", ... } }
```

**BaseTool 接口**：
```python
class CybergymSubmitTool(BaseTool):
    async def create(self, instance_id=None, **kwargs) -> tuple[str, ToolResponse]
    async def execute(self, instance_id, parameters, **kwargs) -> tuple[ToolResponse, float, dict]
    async def release(self, instance_id, **kwargs) -> None
```

**ToolAgentLoop 状态机**：
```
PENDING → GENERATING → PROCESSING_TOOLS → GENERATING → ... → TERMINATED
              │              │
         LLM 输出         执行工具
         tool_call        返回结果
```

### 9.3 CyberGym Server 接口

| 端点 | 方法 | 认证 | 用途 |
|------|------|------|------|
| `/submit-vul` | POST | 无 | 提交 PoC 验证漏洞版本 |
| `/submit-fix` | POST | X-API-Key | 提交 PoC 验证修复版本 |
| `/query-poc` | POST | X-API-Key | 查询 PoC 记录 |
| `/verify-agent-pocs` | POST | X-API-Key | 重新验证某 agent 的所有 PoC |

**Checksum 算法**：`sha256(f"{task_id}{agent_id}{salt}")`, salt 默认 "CyberGym"

**Rate Limit**：200 req/60s per agent（已调高，默认 20）

## 10. 项目结构

```
cybergym_integration/
├── PLAN.md                              # 本文档（飞书方案对齐版）
├── WORK_SUMMARY.md                      # 工作进展总结
│
├── deploy/
│   ├── setup_x86.sh                     # x86 服务器部署
│   └── setup_tunnel.sh                  # SSH 隧道
│
├── data/
│   ├── prepare_data.py                  # CyberGym tasks → verl parquet
│   └── task_list.json                   # Subset 10 任务 ID
│
├── verl_integration/
│   ├── cybergym_reward.py               # 自定义 reward 函数 ✅
│   ├── cybergym_reward_mock.py          # Mock reward ✅
│   ├── cybergym_tools.py                # 工具定义 (read/submit/exec) ✅
│   ├── system_prompt.py                 # Agent system prompt ✅
│   ├── opencode_agent_loop.py           # opencode Agent Loop (待写) 🔄
│   └── tool_config.yaml                 # 工具 YAML 配置 (待写)
│
├── agent_sdk/                           # Ascend AgentSDK 扩展 (待写)
│   ├── cybergym_env.py                  # CyberGymEnv (gen_task/step/reward)
│   ├── opencode_engine_wrapper.py       # OpenCodeEngineWrapper
│   └── trajectory_converter.py          # trajproxy → VERL 格式转换
│
├── configs/
│   ├── train_cybergym.sh                # 训练脚本 ✅
│   ├── train_cybergym_mock.sh           # Mock 训练脚本 ✅
│   └── cybergym_grpo.yaml               # AgentSDK 配置文件 (待写)
│
└── scripts/
    ├── test_reward.py                   # 本地测试 ✅
    ├── test_e2e_minimal.py              # 端到端最小验证 ✅
    ├── evaluate.py                      # 基线评估
    └── pull_docker_images.sh            # Docker 镜像拉取 ✅
```

## 11. 数据格式

### Parquet 格式

```python
{
    "prompt": [
        {"role": "system", "content": "你是安全研究员..."},
        {"role": "user", "content": "任务 arvo:10400 的漏洞描述..."}
    ],
    "data_source": "cybergym",
    "reward_model": {
        "style": "rule",
        "ground_truth": "arvo:10400"
    },
    "extra_info": {
        "task_id": "arvo:10400",
        "difficulty": "level1"
    }
}
```

## 12. 分阶段实施

### Phase 1: 单轮 GRPO 训练验证 ✅ 已完成

- **目标**：验证 reward signal 有效，训练链路跑通
- **结果**：v12 step:1 完成，零错误，轨迹质量正常
- **关键修复**：weight sync crash / master_param / OOM / checkpoint 四大问题

### Phase 2: opencode Agent 多轮交互 🔄 进行中

**步骤**：
1. ✅ x86 Docker 容器启动（ubuntu:24.04, host network, /data 挂载）
2. ⏳ opencode 安装 + deepseek provider 配置（需 DEEPSEEK_API_KEY）
3. ⏳ `opencode serve --port 8099` 启动 HTTP API
4. ⏳ 编写 `opencode_agent_loop.py`（verl `@register("opencode_agent")`）
5. ⏳ 编写 `tool_config.yaml`
6. ⏳ reward 适配多轮轨迹
7. ⏳ 12 节点同步 + 最小链路验证

**opencode Agent 对接详细设计**：

```
训练时:
  vLLM → tool_agent_loop → HTTP POST /session → opencode 容器
  opencode 多轮交互:
    1. 读源码 (read tool)
    2. 分析漏洞 (LLM 推理)
    3. 构造 PoC (write tool → /app/poc)
    4. 测试 (bash tool → 本地运行)
    5. 迭代修改 (多轮)
  轨迹通过 HTTP API 取回 → reward 计算 → GRPO 更新

评估时:
  opencode 直连 deepseek API → 生成 PoC → CyberGym 验证
```

**opencode HTTP API（Legacy v1）**：
```
POST   /session                  → 创建会话，返回 session_id
POST   /session/{id}/message     → 发送消息（触发 Agent 执行）
GET    /session/{id}/message     → 获取 Agent 响应（含工具调用）
```

### Phase 3: trajproxy 轨迹捕获 ⏸ 待评估

**前置条件**：Phase 2 多轮链路跑通

**方案选择**：
- **方案 A**：部署 trajproxy Ray 集群（飞书方案完整版，适合生产）
- **方案 B**：verl 原生 tool_agent_loop（当前架构，轻量级，适合快速验证）

**推荐**：先用方案 B 跑通多轮训练，后续按需升级到方案 A。

### Phase 4: 全异步训练 ⏸ 待实施

**前置条件**：Phase 2/3 多轮训练稳定

- VERL Fully Async Policy Trainer（原生支持）
- TransferQueue 经验队列
- max_staleness=2 + rollout correction
- ARPO Replay Buffer 注入成功轨迹

### Phase 5: 生产化 + 评估

- SEGym 容器池化管理（替换手动 Docker）
- Ascend AgentSDK 统一抽象层
- 完整 vul+fix 双验证评估
- Leaderboard 提交

## 13. 训练参数

### 当前参数（Phase 1 单轮）

| 参数 | 值 | 说明 |
|------|-----|------|
| `train_prompt_bsz` | 16 | batch size |
| `n_resp_per_prompt` | 4 | GRPO group size |
| `max_prompt_length` | 4096 | 漏洞描述较长 |
| `max_response_length` | 1536 | 已调低（v12 验证通过） |
| `use_precision_aware_optimizer` | True | 省显存（必须） |
| `optimizer_cpu_offload` | True | CPU offload |
| `save_freq` | 0 | 禁用 checkpoint |

**并行策略（不变）**：
- Train: TP=4, PP=2, EP=32
- Rollout: TP=8, DP=4, EP=32
- DSpark 投机解码: num_speculative_tokens=5

### 目标参数（Phase 2 多轮）

| 参数 | Phase 1 | Phase 2 | 说明 |
|------|---------|---------|------|
| `max_response_length` | 1536 | 4096 | 多轮需要更多空间 |
| `multi_turn.max_user_turns` | - | 15 | 最大交互轮数 |
| `multi_turn.max_assistant_turns` | - | 15 | |
| `multi_turn.tool_config_path` | - | tool_config.yaml | |
| `agent.name` | - | opencode_agent | |
| `train_batch` | 16 | 64 | 异步模式更大 batch |

## 14. 关键修复记录

| 问题 | 根因 | 修复 | 影响范围 |
|------|------|------|---------|
| weight sync crash | vllm-ascend MoE 权重转置 + shard_dim 计算错误 | kernel layout 检测 + 参数 revert | 12 节点 deepseek_v4.py |
| master_param KeyError | CPU offload state 缺 master_param | fallback to sharded_model_param | 12 节点 distrib_optimizer.py |
| NPU OOM (56.45GB) | use_precision_aware_optimizer=False | 必须保持 True | train_cybergym.sh |
| checkpoint shape mismatch | 保存时参数 shape 不一致 | save_freq=0 禁用保存 | train_cybergym.sh |
| 脚本分发失败 | 只改了 head 节点 | scp + docker cp 到全部 12 节点 | 部署流程 |

## 15. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| **Reward 稀疏** | GRPO 无法学习，全 0 | 格式奖励 +0.1；选简单任务；ARPO 注入成功轨迹 |
| **容器验证慢** | reward 计算瓶颈 | 同网段 0.19s 延迟（已验证）；训练模式只跑 vul |
| **x86 Server 宕机** | 全部 reward 变 -1 | reward 函数不因 -1 惩罚模型 |
| **黑盒轨迹丢失** | 训推不一致 | trajproxy Token-in-Token-out 模式 |
| **多轮 token 爆炸** | 上下文溢出 | max_turns=15 限制；autoCompact=OFF 保留完整轨迹 |
| **Policy staleness** | 异步训推差异 | max_staleness=2 + rollout correction |
| **PoC 逃逸** | 安全风险 | network=none + 物理分池 |

## 16. 上游源码索引

```
server_code/verl/                            # verl 训练框架
  ├── verl/trainer/ppo/reward.py             # reward 加载入口
  ├── verl/workers/reward_manager/batch.py   # BatchRewardManager
  ├── verl/experimental/agent_loop/
  │   ├── tool_agent_loop.py                 # ToolAgentLoop 状态机
  │   └── single_turn_agent_loop.py          # 单轮 Agent Loop
  └── verl/tools/
      ├── base_tool.py                       # 工具基类
      └── utils/tool_registry.py             # 工具注册表

CyberGym (cybergym/)                         # 漏洞验证框架
  ├── src/cybergym/server/__main__.py        # FastAPI Server
  ├── src/cybergym/server/server_utils.py    # Docker 容器验证
  ├── src/cybergym/server/types.py           # Payload + ServerConfig
  ├── src/cybergym/server/rate_limiter.py    # 滑动窗口限流
  ├── src/cybergym/task/gen_task.py          # 任务文件生成
  └── src/cybergym/task/types.py             # Task 模型 + verify_task()
```

## 17. x86 Server 部署详情

**环境**：Ubuntu 24.04, 32C/64GB, vdb 196GB (71% 已用)

**Docker 镜像状态**：

| 任务 ID | vul | fix | 备注 |
|---------|-----|-----|------|
| arvo:47101 | ✅ | ❌ | fix 拉取超时 |
| arvo:3938 | ✅ | ✅ | |
| arvo:24993 | ✅ | ❌ | fix 拉取超时 |
| arvo:1065 | ✅ | ✅ | |
| arvo:10400 | ✅ | ❌ | fix 拉取超时 |
| arvo:368 | ✅ | ✅ | |
| oss-fuzz:42535201 | ✅ | ✅ | |
| oss-fuzz:42535468 | ✅ | ✅ | |
| oss-fuzz:370689421 | ✅ | ✅ | |

**联调测试**：23/23 通过，延迟 avg 0.19s

**OpenCode Agent 容器**：
- 名称：opencode-agent
- 镜像：ubuntu:24.04
- 网络：host
- 挂载：/data
- 状态：已启动，opencode 安装进行中
