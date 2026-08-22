# CyberGym-E2E 落地评估方案

> 基于：现有后训练基础设施盘点 × E2E 源码级分析
> 日期: 2026-08-22
> 前提: 正式方案（OpenHands + trajproxy）正在 T1 阶段推进中

---

## 一、我们已有的资产清单

### 1.1 集群侧（12 节点 Ascend 910B）

| 资产 | 状态 | E2E 可复用性 |
|------|------|-------------|
| 64 训练 NPU（Megatron GRPO） | ✅ v2 运行中 | ✅ 策略模型训练 |
| 32 推理 NPU（vLLM, TP=8/DP=4） | ✅ 运行中 | ✅ 策略模型推理端点 |
| verl 框架 + tool_agent_loop | ✅ 已跑通 | ⚠️ 部分复用（E2E 交互模式不同） |
| DSpark 投机解码 | ✅ 已配置 | ✅ 加速推理 |
| HCCL 权重同步 | ✅ 已修复 | ✅ |

### 1.2 x86 侧（192.168.0.100, 32C/64GB/492GB）

| 资产 | 状态 | E2E 可复用性 |
|------|------|-------------|
| Docker + 500M 带宽 | ✅ | ✅ E2E 大量容器操作 |
| CyberGym Server :8666（binary 模式） | ✅ 运行中 | ❌ **E2E 不用这个**（自带 validate.py） |
| 130GB binary 数据（1507 任务） | ✅ | ❌ E2E 用自己的数据集 |
| runner 镜像（oss-fuzz-base-runner） | ✅ | ❌ E2E 用 base-builder 镜像 |
| trajproxy 源码 + 部署（T1 进行中） | 🔄 | ✅ 轨迹捕获 |
| 源码包 ~1368 arvo 任务 | ✅ | ⚠️ 部分重叠（E2E 有自己的 src.tgz） |

### 1.3 软件资产

| 资产 | 状态 | E2E 可复用性 |
|------|------|-------------|
| OpenHands 正式方案（T1-T5） | 🔄 T1 | ✅ 同一 harness |
| final-submission 计分 | ✅ | ⚠️ E2E 用四阶段，需适配 |
| 轨迹落盘（trajectory dump） | ✅ | ✅ |
| perf_dashboard.py | ✅ | ✅ 可扩展 |
| preflight 预检体系 | ✅ | ✅ 可扩展 |
| v2 基线（native 训练） | ✅ 运行中 | 对照组 |

---

## 二、E2E 需要什么（源码级确认）

### 2.1 数据

```
HF: sunblaze-ucb/cybergym-e2e
  每任务: src.tgz（源码快照）+ poc.bin（标准PoC）+ crash.log（崩溃报告）
  920 任务 / 139 项目
  中位数源码: 1,811 文件 / 613K 行
```

### 2.2 Docker 镜像（关键差异！）

```
E2E 用的是 OSS-Fuzz base-builder 镜像（编译环境）:
  gcr.io/oss-fuzz-base/base-builder@sha256:8eda74a...  ← 主力镜像
  n132/arvo:<id>-fix                                    ← 部分任务复用 ARVO 镜像

与我们现有镜像的区别:
  我们: oss-fuzz-base-runner（只跑二进制，不编译）
  E2E:  base-builder（含完整编译工具链: clang/cmake/make/ninja）
        → Agent 需要在容器内【编译项目】来验证补丁
```

**统计: 30 个不同镜像（base-builder 为主 + 部分 ARVO 修复镜像）**

### 2.3 容器内布局

```
每个任务的 Agent 容器:
  /src/       ← 源码（从 src.tgz 解压）+ 编译脚本
  /config/    ← config.toml（vul_commit + patch_commit）
  /data/      ← ground truth PoC（e2e 模式不给 agent）
  /output/    ← agent 写 poc.bin 和 fix.patch
  /scripts/   ← validate.py（agent 可自主调用做中间验证）
```

### 2.4 LLM 接入

```
支持: OpenAI 兼容 API / Anthropic / Bedrock / LiteLLM
OpenHands 已内建支持（get_llm_env 配置环境变量）

关键: OPENAI_BASE_URL 环境变量 → 可指向我们的 vLLM 或 trajproxy
```

### 2.5 验证流水线（与 CyberGym 的根本差异）

```
CyberGym（我们现有的）:
  提交 PoC → server 判定 → 秒级返回 exit_code

E2E:
  Agent 在容器内自主调用 validate.py
  → 每个阶段: 恢复源码 → 应用补丁 → 重编译（最长 1h）→ 跑 PoC / 跑测试
  → 四阶段顺序执行，每阶段独立容器

时间对比:
  CyberGym 单次验证: ~0.2 秒
  E2E 单次四阶段:   ~10-60 分钟（编译占大头）
```

---

## 三、Gap 分析（缺什么）

| # | 缺失组件 | 严重度 | 工作量估算 | 说明 |
|---|---------|--------|-----------|------|
| 1 | **E2E 数据集下载** | 🔴 必须 | 2-4h（HF 下载） | 920 任务的 src.tgz/poc.bin/crash.log |
| 2 | **base-builder 镜像拉取** | 🔴 必须 | 1-2h | 30 个镜像，含编译工具链，预计 ~50-100GB |
| 3 | **E2E runner 部署** | 🔴 必须 | 2h | run_agent.py + validate.py + utils.py 已有源码 |
| 4 | **LLM 端点对接** | 🟡 需适配 | 1h | OPENAI_BASE_URL 指向 vLLM/trajproxy |
| 5 | **RL 训练适配** | 🟡 大工作量 | 2-3 天 | E2E 的 reward 结构（四阶段）映射到 GRPO |
| 6 | **编译加速** | 🟡 可选 | 1 天 | 缓存编译产物 / 增量编译 / 预编译镜像 |
| 7 | **ASLR 配置** | 🟢 小 | 5min | `sysctl vm.mmap_rnd_bits=28`（sanitizer 兼容） |

---

## 四、两种落地路径

### 路径 A：纯评测（先跑通，不改训练）

**目标**: 用 E2E 评测我们训练出的模型，得到官方口径成绩

```
┌─────────────────────────────────────────────┐
│  x86 物理机                                  │
│                                             │
│  E2E Runner（run_agent.py + validate.py）    │
│    ├── Agent 容器（base-builder 镜像）        │
│    │     ← LLM 调用指向集群 vLLM              │
│    │     （或 OpenHands 指向 trajproxy）      │
│    └── 四阶段验证（独立容器逐阶段执行）         │
│                                             │
│  不需要 verl / GRPO / trajproxy（纯推理）     │
└─────────────────────────────────────────────┘
```

**所需步骤**:

| 步骤 | 内容 | 依赖 |
|------|------|------|
| E1 | HF 下载 E2E 数据集到 x86 | 500M 带宽 |
| E2 | 拉取 30 个 base-builder 镜像 | Docker Hub / GCR |
| E3 | x86 安装 E2E 依赖 + ASLR 配置 | Python 3.12 |
| E4 | LLM 端点: vLLM 暴露 OpenAI API 或用 checkpoint 起服务 | 集群侧 |
| E5 | 单任务跑通: `run_agent.py curl/arvo_66012 --mode e2e` | E1-E4 |
| E6 | 批量评测: `batch_run.sh` 920 任务 | E5 |

**时间估算**: 1-2 天部署 + 评测运行 ~920×90min÷4并发 ≈ **14.4 天**（纯评测不训练）

### 路径 B：RL 训练（E2E 作为训练环境）

**目标**: 在 E2E 环境中做 GRPO 强化学习训练

```
┌─────────────────── x86 ───────────────────┐     ┌── 集群 ──┐
│  E2E 任务容器 ×N（base-builder）            │     │          │
│    Agent 在容器内工作（编译/测试/迭代）      │     │  vLLM    │
│        │ LLM 调用                          │────│──│ ←策略   │
│        ▼                                  │     │  模型    │
│  trajproxy（TITO 捕获 token+logprob）      │     │          │
│        │                                  │     │  verl    │
│        ▼                                  │     │  GRPO    │
│  Reward: 四阶段验证结果 → final reward     │────│──│ →更新   │
│                                           │     │  权重    │
│  挑战: 编译耗时（每轨迹 10-60min）           │     └──────────┘
└───────────────────────────────────────────┘
```

**额外挑战**（路径 A 没有的）:

| 挑战 | 影响 | 缓解方案 |
|------|------|---------|
| **编译极慢** | 每次验证需重编译（3600s timeout），RL 迭代成本极高 | 预编译缓存 / 增量编译 / 只验 S1 |
| **上下文爆炸** | 613K 行源码，agent 需要大量阅读 | 上下文管理 / 分段阅读 / 工具化检索 |
| **reward 极稀疏** | S3 通过率 ~20%（顶尖模型）→ RL 初期可能无梯度 | 分阶段 reward（S1=0.3/S2=0.3/S3=0.4）/ 课程学习 |
| **容器生命周期** | 每轨迹一个容器，编译态需持久化跨阶段 | 容器池 + 编译缓存卷 |
| **并发瓶颈** | 64GB 内存 × base-builder 镜像 → 并发 8-16 | 扩容或降低并发 |

**时间估算**: 5-7 天开发适配 + 训练周期以周计

---

## 五、与现有正式方案的关系

```
当前正式方案（OPENHANDS_FORMAL_PLAN.md）:
  CyberGym（原版）+ OpenHands + trajproxy → PoC 生成 RL 训练
  状态: T1 进行中

E2E 方案的定位:
  ┌── 近期: 用路径 A 做"终极评测"（不改训练，纯推理评测）
  │   → 训完的模型在 E2E 上跑分 → 论文级成绩单
  │
  ├── 中期: 如果 CyberGym 训练效果好 → E2E 评测验证迁移能力
  │   → CyberGym 学到的"找漏洞+构造PoC"能否迁移到 E2E 的完整流程
  │
  └── 远期: 路径 B，E2E 作为训练环境
      → 加入补丁生成能力
      → 四阶段作为分阶段 reward
      → 这是终极目标但工程量最大
```

**建议优先级**:
1. ✅ **继续当前正式方案**（CyberGym PoC RL 训练）—— 这是最快能出训练结果的
2. 📋 **并行准备 E2E 评测环境**（路径 A）—— 等模型训好就能评
3. ⏳ **远期再考虑路径 B**（E2E RL 训练）—— 等前两步验证了价值

---

## 六、如果要立即启动路径 A（评测）的准备清单

| # | 任务 | 预计耗时 | 前置 |
|---|------|---------|------|
| 1 | `hf download sunblaze-ucb/cybergym-e2e` 到 x86 | 2-4h | HF_TOKEN |
| 2 | `python scripts/pull_images.py`（30 个镜像） | 1-2h | x86 Docker |
| 3 | x86: `apt install sudo git` + `pip install tomli tomli_w httpx docker` | 15min | — |
| 4 | `sysctl -w vm.mmap_rnd_bits=28`（ASLR） | 1min | root |
| 5 | vLLM 暴露 OpenAI 端点（或用独立推理服务） | 1h | 集群 |
| 6 | 单任务验证: `run_agent.py curl/arvo_66012 --mode e2e` | 30min | 1-5 |
| 7 | 批量: 选取 50-100 任务子集先跑 | 数小时 | 6 |

**磁盘需求**: E2E 数据 ~20-50GB + 镜像 ~50-100GB = 新增 ~100-150GB
（x86 当前剩余 144GB → **需要清理旧镜像释放 ~180GB**）

---

## 七、结论

| 维度 | 评估 |
|------|------|
| **技术可行性** | ✅ 完全可行——E2E 代码已 clone，架构清晰，LLM 接口兼容 |
| **与现有设施复用** | ~60%（集群推理/训练/Docker/监控复用；验证流水线/镜像/数据需新建） |
| **最大瓶颈** | 编译耗时（E2E 每次验证 10-60min vs CyberGym 0.2s） |
| **推荐策略** | 近期评测（路径A）+ 远期训练（路径B），当前继续 CyberGym RL |
| **启动成本** | 路径A: 1-2 天部署；路径B: 5-7 天开发 |
