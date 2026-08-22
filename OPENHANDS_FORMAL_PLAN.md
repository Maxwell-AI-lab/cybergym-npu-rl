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
