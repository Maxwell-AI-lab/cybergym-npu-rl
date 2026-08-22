# 正式训练方案：OpenHands + trajproxy + verl 全链路

> **决策记录**：2026-08-22 用户拍板"按正式的方案来搞，按 OpenHands 的对接方案"。
> 本文档是唯一权威实施计划，按步骤逐项落地，每步有验收标准。
> 前置调研已完成：官方 cybergym-agent-examples（OpenHands/Cybench/EnIGMA/Codex）、
> arvo_task.py 官方任务语义、FAQ 计分口径、trajproxy 完整源码分析、CYBERGYM_EVAL_INFO.md。

---

## 1. 为什么是这条路线（背景与依据）

| 依据 | 结论 |
|------|------|
| 官方评测用 OpenHands 等 agent 容器跑（每任务一个沙箱） | 训练=评测同构，消除迁移损耗 |
| 官方任务语义：工作区含 源码+描述+README+submit.sh，PoC 为文件 | 已对齐（v3 工具层） |
| 官方 FAQ Q3：允许多次提交，推荐 final-submission 计分 | 已实现 |
| 论文事实：所有 level 都给源码；顶尖 Agent ~20% 成功率 | 源码必上；预期基线明确 |
| 策略模型的 logprob 必须精确捕获 → trajproxy（TITO 模式，官方保真度 >0.99） | 复用 trajproxy |

**放弃的替代路线**：native tool loop 训练（吞吐高 3 倍但 harness 不与官方评测同构）。
**保留为回退保险**：native 链路全部资产保留可用。

## 2. 目标架构

```
                    x86 物理机 (192.168.0.100, 32C/64G/492G)
┌─────────────────────────────────────────────────────┐
│  OpenHands runtime 容器 × 12~24 并发                  │
│  每任务/每轨迹一个:                                    │
│    workspace = repo-vul.tar.gz + description.txt      │
│              + README.md + submit.sh（官方模板生成）    │
│    agent 行为: 解压源码 → 读码分析 → 写 PoC 文件        │
│              → bash ./submit.sh PATH（可多次）         │
│        │ LLM 调用（base_url 带 /s/{trial_id}/ 前缀）   │
│        ▼                                             │
│  trajproxy（Docker, 2 workers, :12300-12304）         │
│    · TITO 模式: token_ids + per-token logprobs 捕获   │
│    · trial_id 会话隔离 · 前缀缓存 · PostgreSQL 存储     │
│        │ 转发                                         │
├────────┼─────────────────────────────────────────────┤
│  CyberGym Server :8666（binary 模式）                  │
│    vul/fix 验证容器（亚秒级，1507 任务全覆盖）           │
└────────┼─────────────────────────────────────────────┘
         ▼ 集群侧
   vLLM（rollout 节点, verl 训练引擎的策略端点, OpenAI 兼容）
         ▼
   TrajectoryConverter: 同 trial 连续请求拼接
     （OpenHands 构造上下文 mask=0 / 模型输出 mask=1）
         ▼
   verl GRPO 更新 → 权重同步回 vLLM → 下一 step
```

## 3. 组件清单与当前状态

| # | 组件 | 位置 | 状态 |
|---|------|------|------|
| 1 | 源码包 1507 任务 | relay（合并中 ~90%+） | 🔄 x86→relay 合并 + 四级校验待跑 |
| 2 | binary 判决 | x86 :8666 | ✅ 全量可用（已实测） |
| 3 | trajproxy 源码 | x86 /data/trajproxy | ✅ 已克隆 |
| 4 | trajproxy 运行时 | x86 | 🔄 部署中（postgres 容器 + proxy 容器） |
| 5 | OpenHands | 待部署 | ⏳ 按官方示例锁定版本 |
| 6 | vLLM 策略端点 | 集群 rollout | ✅ verl vLLMHttpServer 存在，需暴露配置 |
| 7 | TrajectoryConverter | 待开发 | ⏳ 核心开发件（拼接+mask+格式） |
| 8 | verl 训练侧消费 | 待开发 | ⏳ 编排 OpenHands 采样 → 转换 → GRPO |
| 9 | v2 native 基线 | 集群 | 🔄 运行中（对照组，建议跑完当前量） |

## 4. 分阶段实施计划（每步有验收门）

### Phase T1：x86 基础设施（0.5 天）
```
1.1 PostgreSQL 容器（traj_db, :5433, 数据卷持久化）
    验收: pg_isready 通过
1.2 trajproxy 容器（2 workers, :12300-12304）
    验收: GET :12300/health = 200
1.3 tokenizer 挂载（DS4 tokenizer → /app/models/dsv4）
    验收: worker 日志显示 tokenizer 加载成功
1.4 注册策略模型（deepseek-v4-flash → 集群 vLLM 占位 URL）
    验收: /models 列出该模型
```

### Phase T2：OpenHands 部署与单任务接线（1 天）
```
2.1 按官方示例锁定 commit 构建 OpenHands（x86）
2.2 官方 gen_task 生成任务工作区
    （源码+描述+README+submit.sh，难度 level1）
    验收: 工作区文件与官方 prepare_arvo_files 产物一致
2.3 OpenHands LLM 配置指向 trajproxy
    （base_url = http://x86:12300/s/{trial_id}/v1）
2.4 单任务端到端: OpenHands 容器内 agent 解题 → 多次 submit.sh
    验收: ① agent 真实读写源码 ② 提交到达 :8666 ③ 拿到 exit_code
```

### Phase T3：轨迹捕获验证（0.5 天）——最关键的验收
```
3.1 TITO 捕获检查: trajproxy DB 里该 trial 的每条请求
    均有 token_ids + logprobs + full_conversation_token_ids
3.2 保真度抽验: 抽 3 条请求，用集群侧重算 logprob 对比
    验收: 相对误差 < 1%（对齐官方 >0.99 保真度声明）
3.3 多 trial 隔离: 并发 2 个 trial，轨迹不串
```

### Phase T4：TrajectoryConverter + verl 集成（1.5-2 天，最难）
```
4.1 Converter 开发:
    同 trial 请求序列 → 单条训练样本
    · 上下文部分(OpenHands 构造) mask=0
    · 模型生成部分 mask=1 + logprobs
    · reward = final-submission 解析（复用现有实现）
4.2 verl 编排开发: 每 step 并发 N 个 OpenHands 沙箱
    → 收集 trial → 转换 → GRPO 更新 → 权重回同步 vLLM
4.3 小规模闭环: 4 任务 × 8 trial
    验收: loss 正常、reward 流入、权重更新生效
```

### Phase T5：正式训练发射（0.5 天）
```
5.1 并发压测: x86 12-24 沙箱并发 + 判决容器共存
5.2 checkpoint 修复（多天训练保险，可与 T4 并行做）
5.3 正式发射: 任务子集起步（建议 100-300）→ 稳定后放量 1507
```

## 5. 时间线与吞吐预期

```
T1-T2: 今天-明天    T3: 明天晚    T4: 后天起 2 天    T5: 第 4-5 天
端到端: 约 4-5 个工作日完成正式发射

吞吐代价（透明）:
  沙箱并发 12-24（x86 64G 内存约束）
  step 时间 ~2.5-3h（native 是 1h）
  100 任务 ≈ 4 step/epoch ≈ 12h/epoch
  1507 任务全量 epoch ≈ 6-7 天
```

## 6. 风险与回退

| 风险 | 缓解 |
|------|------|
| trajproxy 保真度不达标 | T3 强验收门（1% 误差）；不过 → 修复或回退 native |
| OpenHands 与自建 vLLM 兼容问题 | 提前在 T2 用单任务打通；锁版本 |
| x86 沙箱并发不足拖慢训练 | 加机器/降任务集/混合模式（native 产出+OpenHands 评测校准） |
| 长链路调试复杂 | 每 Phase 独立验收；v2 native 全程保留为对照与回退 |

## 7. 待用户确认的三个问题

1. **吞吐取舍**：step 时间 3 倍化（2.5-3h/step）是否接受？若可加机器跑 OpenHands 沙箱，并发可线性提升
2. **任务池起步规模**：正式训练先 100-300 子集验证放量，还是直接全量 1507？
3. **v2 native 基线**：是否继续跑完当前训练量作为对照组（不占 x86，只占集群）？

---

## 8. 用户决策记录（2026-08-22）

| 决策项 | 内容 |
|--------|------|
| 并发策略 | **前期小并发起步**（4-8 沙箱），验证稳定后用户扩容硬件提并发 |
| 任务池 | **前期小批量验证**（100 任务子集），链路稳定后放量 |
| v2 native 基线 | **结果归档到 V2_BASELINE_REPORT.md，正式方案跑通后停掉** |
| 质量纪律 | 全方案入文档、分步实施、完善质量保障、进展归档 GitHub |

## 9. OpenHands 容器架构（内部组件）

两层结构：
- **Controller（主程序）**：事件循环 + CodeActAgent 策略 + LLM 抽象层（接 trajproxy）+ 工具调度 + 轨迹落盘。按官方示例 make build 锁 commit。
- **Runtime 容器（沙箱）**：官方通用镜像
  `docker.all-hands.dev/all-hands-ai/runtime:0.33-nikolaik`，内部含：
  ① OS 基底 ② openhands-runtime 服务进程（执行 controller 发来的 bash/文件指令）
  ③ 工具链（bash/git/python3/node/curl） ④ /workspace 工作目录
  （任务文件挂载注入，不烧进镜像——一个镜像服务全部 1507 任务）

任务注入：官方 prepare_arvo_files 生成工作区（repo-vul.tar.gz +
description.txt + README.md + submit.sh）→ 挂载为 workspace。
LLM 接线：config.toml 的 base_url = http://x86:12300/s/{trial_id}/v1。

## 10. 质量保障体系（QA）

### 10.1 逐 Phase 验收门（不达标不放行）

| Phase | 验收门 |
|-------|--------|
| T1 | /health 200；tokenizer 加载成功；模型注册可见 |
| T2 | 单任务端到端：agent 真实读源码、submit 到达 :8666、拿到 exit_code |
| T3 | **保真度 <1%**（抽样 3 条用集群重算对比）；多 trial 隔离无串扰 |
| T4 | 4 任务×8 trial 闭环：loss 正常、reward 流入、权重更新生效 |
| T5 | 12-24 并发压测稳定；checkpoint 保存恢复正常 |

### 10.2 持续质量检查（训练期常驻）

1. **判决侧健康**：infra_error 比例 >5% 告警（preflight + dashboard）
2. **轨迹完整性**：每 step 轨迹数 = 沙箱数；converter 拼接无缺段
3. **保真度巡检**：每 N step 抽 1 条轨迹重算 logprob 对比
4. **计分正确性**：final-submission 解析率监控（unknown 占比 <2%）
5. **回归保护**：scripts/preflight_check.sh 启动前强制全绿
6. **监控双端**：集群（进程/reward）+ x86（负载/容器/延迟）

### 10.3 归档纪律

- 每个里程碑（Phase 完成/异常/决策）记入 PROGRESS_LOG.md
- 每次会话结束前 git commit + push 到 Maxwell-AI-lab/cybergym-npu-rl
- 基线与正式方案数据分目录归档（V2_BASELINE_REPORT.md / 正式期报告）

## 11. 进度日志

见 PROGRESS_LOG.md（持续追加）。

---

## 12. 沙箱层横向扩容设计（OpenHands 容器池）

### 12.1 设计原则

沙箱层（OpenHands runtime 容器）与中心服务**解耦**为可扩展资源池：

```
                 ┌─────────── 中心服务（留在 x86，轻量）───────────┐
                 │ trajproxy :12300（轨迹捕获，聚合点）             │
                 │ CyberGym :8666（判决，亚秒容器）                 │
                 │ PostgreSQL :5433（轨迹存储）                     │
                 └──────────────△──────────────△──────────────────┘
                                │              │ (全部只需 HTTP 可达)
        ┌───────────────────────┴──┐        ┌─┴────────────────────┐
        │ 沙箱主机 A（x86 本机）      │        │ 沙箱主机 B（新增服务器）│
        │ OpenHands 容器 × 12~24    │        │ OpenHands 容器 × M    │
        └──────────────────────────┘        └──────────────────────┘
           扩容 = 加主机 → 注册进池 → 调度器自动分流
```

**关键解耦点**：沙箱主机只需三样东西——
1. Docker + 官方 runtime 镜像（`docker pull` 一次）
2. 到 x86 的 **HTTP 可达**（trajproxy :12300 + CyberGym :8666，都是普通 HTTP，无状态）
3. 任务工作区材料（源码包，见 12.3 分发策略）

**不需要**：集群访问、NPU、大存储（工作区按任务临时生成，用完清理）。

### 12.2 沙箱主机注册表（sandbox_hosts.yaml）

```yaml
# 编排器读取；加机器 = 在这里加一行 + 主机上跑一次 prep 脚本
hosts:
  - name: x86
    addr: 192.168.0.100
    max_containers: 20        # 按 (内存-2G)/1.5G 估算
    docker: local             # local=本机 docker; remote=ssh docker
  - name: sandbox-b           # ← 未来新增的服务器
    addr: 192.168.0.101
    max_containers: 30
    docker: remote            # ssh root@addr 方式调度
```

### 12.3 新主机接入流程（prep_sandbox_host.sh，一条命令）

```bash
# 在新主机上执行：
1. docker pull docker.all-hands.dev/all-hands-ai/runtime:0.33-nikolaik
2. mkdir -p /data/cybergym_workspaces            # 工作区根目录
3. curl http://<x86>:12300/health                 # 连通性自检
4. curl http://<x86>:8666/docs                    # 判决连通性自检
# 然后在编排器配置里注册该主机 → 立即参与调度
```

**工作区材料分发**（三选一，按规模演进）：
- **阶段1（≤3 主机）**：编排器 scp 源码包到目标主机再起容器（当前默认，简单）
- **阶段2**：NFS 共享源码库（relay /data 已是 NFS，挂载即可，零拷贝）
- **阶段3**：对象存储按需拉取（远期，多机房场景）

### 12.4 调度器（编排器内置，~100 行）

```
调度逻辑: 任务到达 → 选主机（最少占用优先）→ 该主机:
  ① 准备工作区(generate_task: 源码+描述+README+submit.sh)
  ② docker run runtime 容器(workspace 挂载, trial_id 注入 base_url)
  ③ 超时回收(20min) → 容器销毁 → 工作区清理
故障处理: 主机失联 → 该主机任务重派; 容器异常退出 → 记录并重试(≤2次)
```

### 12.5 扩容容量模型

| 主机规格 | 并发容器 | 说明 |
|----------|---------|------|
| x86 (32C/64G) | 12~24 | 已就绪 |
| 典型新主机 (16C/32G) | ~12 | 每容器 ~1.5-2G 内存封顶 |
| 每加 1 台 32G 主机 | +12 轨迹并发 | step 时间近似线性缩短 |

**吞吐示例**：3 台 32G 主机 ≈ 36 并发 → 128 轨迹/step 的沙箱阶段 ≈ 70 分钟（当前单 x86 ~2.5h 的 1/2）。

### 12.6 与中心服务的扩展关系

| 组件 | 是否需要跟着扩 | 原因 |
|------|--------------|------|
| trajproxy | 暂不需要 | 代理聚合，单机轻松支撑 24+ 沙箱的 LLM 调用（瓶颈在集群 vLLM 吞吐） |
| CyberGym 判决 | 永不需要 | 实测利用率 <5% |
| PostgreSQL | 暂不需要 | 轨迹写入量小 |
| 集群 vLLM | **真正的吞吐上限** | 沙箱扩到一定数量后，瓶颈转移到策略端点的生成吞吐（rollout NPU 可按需从训练侧调配） |

---

## 13. 架构对比：Native vs Formal（通信模型差异）

### 13.1 为什么 native 不需要端口

```
┌─────────────── Ray 集群内部（v2/v3 native 训练）───────────────┐
│                                                               │
│  verl 编排器 → tool_agent_loop (Ray Actor)                     │
│                    ↓ 进程内调用（Ray IPC）                      │
│                vLLM 引擎（同一 Ray 生态）                       │
│                    ↓ 进程内返回 token + logprob                │
│                轨迹 → GRPO 更新                                 │
│                                                               │
│  全部在集群内部: Ray Actor 之间的方法调用，零网络开销              │
│  不需要暴露任何端口，不需要 HTTP                                 │
└───────────────────────────────────────────────────────────────┘
```

### 13.2 为什么正式方案必须有端口

```
┌── x86 物理机 ──────────┐          ┌── 集群（4 rollout 节点）──────┐
│                        │          │                              │
│  OpenHands 容器         │──HTTP──► │  trajproxy ──────HTTP──────► │ vLLM :9090
│  (独立 Docker 进程)     │  必须    │  (捕获 token+logprob)         │ (TP8/DP4/EP32)
│                        │  走网络  │                              │
└────────────────────────┘          └──────────────────────────────┘

核心原因: OpenHands 是 x86 上的独立 Docker 容器，不在 Ray 集群里。
它调用 LLM 的唯一方式是 HTTP 请求（OpenAI API 格式）。
→ vLLM 必须暴露网络端口（:9090），端口就是两个世界的桥梁。
→ trajproxy 卡在中间拦截 HTTP 调用，捕获 token 级 logprob（训练数据）。
```

### 13.3 两种方案的完整对比

| 维度 | Native（v2/v3 当前） | Formal（OpenHands + trajproxy） |
|------|---------------------|--------------------------------|
| Agent 运行位置 | Ray Actor 内（集群） | x86 Docker 容器（独立） |
| LLM 调用方式 | Ray IPC（进程内） | HTTP → trajproxy → HTTP → vLLM |
| 是否需要端口 | ❌ 不需要 | ✅ vLLM :9090 + trajproxy :12300 |
| 轨迹捕获 | 原生（进程内天然可得） | trajproxy 拦截 HTTP 捕获 |
| logprob 精度 | 精确（同一进程） | 依赖 trajproxy 保真度（>0.99） |
| 沙箱隔离 | 共享进程 + 工作区目录 | 每轨迹独立 Docker 容器 |
| 吞吐 | ~60 min/step | ~150-180 min/step |
| 训评一致性 | 工具语义已对齐，但 harness 自建 | 完全与官方评测同构 |
| 并发扩展 | 受限于集群 NPU | 沙箱池可横向加机器（§12） |
| 部署复杂度 | 低（全在集群内） | 高（x86 + 集群 + 网络） |

### 13.4 策略端点的正确配置（关键修正记录）

```
❌ 错误尝试: 单节点 standalone vLLM serve (TP=8)
   → OOM: 256 MoE experts 需分散到 32 卡（EP=32），单节点 8 卡装不下
   → 即使用 gpu-memory-utilization=0.95 + max-model-len=4096 仍然差 514MB

✅ 正确方案: verl 多节点训练的 rollout 引擎 (TP8/DP4/EP32)
   → 4 rollout 节点 × 8 NPU = 32 卡，experts 均匀分散
   → vLLM :9090 自动暴露（OpenAI 兼容 API）
   → 训练本身 = 策略端点（不需要单独起 serve）
```

**教训**：DeepSeek V4 Flash 的 MoE 架构（256 experts）决定了必须多节点 EP，
任何单节点推理方案都不可行。用户原有 verl 配置（TP8/DP4/EP32）是唯一正确路径。
