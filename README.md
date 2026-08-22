# CyberGym NPU RL

**CyberGym 漏洞分析任务的 RL 后训练**（UC Berkeley, ICLR 2026 benchmark）：在 12 节点昇腾 910B 集群 + x86 服务器上，按**官方评测架构**（OpenHands Agent + trajproxy 轨迹捕获 + verl GRPO）对 DeepSeek V4 Flash 做多轮强化学习——模型在官方语义的容器沙箱里读源码、定位漏洞、构造 PoC，由 CyberGym 官方验证服务（vul/fix 双容器）判定，轨迹经 trajproxy 精确捕获（token + logprob）供 GRPO 更新。

> **当前状态**（2026-08-22）：正式架构建设中（T1 完成：trajproxy 已上线）。
> v2 native 基线已归档（`V2_BASELINE_REPORT.md`，1,134 轨迹，4.9% 满分率）。
> 实施计划见 `OPENHANDS_FORMAL_PLAN.md`，里程碑见 `PROGRESS_LOG.md`。

---

## 一、总体方案（三阶段）

| 阶段 | 内容 | 状态 |
|------|------|------|
| **Phase A · 链路打通** | verl 原生多轮 Agent 七轮迭代（r1-r7），首个非零 reward，全链路验证 | ✅ 完成 |
| **Phase B · 基线建立** | v2 全量训练（1507 任务 × 3 epochs，final-submission 计分，binary-only 判决） | ✅ 归档 |
| **Phase C · 正式架构** | OpenHands 沙箱 + trajproxy TITO 捕获 + verl GRPO（训评同构） | 🔄 进行中 |

## 二、目标架构视图（正式方案）

```
┌─────────────────────── x86 物理机 (192.168.0.100 · 32C/64G/492G) ───────────────────────┐
│                                                                                        │
│  ┌─ OpenHands Runtime 容器 ×N ─────────────────────────────────────────────────────┐    │
│  │ 官方通用镜像 · 每任务/每轨迹一个实例                                              │    │
│  │ workspace(挂载注入): repo-vul.tar.gz + description.txt + README.md + submit.sh  │    │
│  │ agent 行为: 解压源码 → 读码分析 → 写 PoC 文件 → bash ./submit.sh PATH(可多次)    │    │
│  └──────────────┬─────────────────────────────────────────────────────────────────┘    │
│                 │ LLM API (base_url = http://…/s/{trial_id}/v1 ← 会话路由)            │
│                 ▼                                                                      │
│  ┌─ trajproxy (:12300-12304, 2 workers) ──────────────────────────────────────────┐    │
│  │ · TITO 模式: token_ids + per-token logprobs 捕获（保真度 >0.99）                │    │
│  │ · trial_id 会话隔离 · 前缀缓存 · PostgreSQL(:5433) 存储                          │    │
│  └──────────────┬─────────────────────────────────────────────────────────────────┘    │
│                 │ 透明转发                                                             │
│  ┌─ CyberGym Server (:8666, binary-only 模式) ─────────────────────────────────────┐   │
│  │ · 1507 任务全量判决（130GB 官方二进制数据包 + 通用 runner 镜像）                  │   │
│  │ · vul/fix 验证容器: 亚秒级生灭 · network=none · PoC hash 去重 · checksum 防作弊  │   │
│  └─────────────────────────────────────────────────────────────────────────────────┘   │
└──────────────────────┬─────────────────────────────────────────────────────────────────┘
                       │ OpenAI 兼容 API
                       ▼
┌─────────────────── 训练集群 (12 × Ascend 910B, aarch64) ──────────────────────────────┐
│  vLLM 策略端点 (rollout 节点, TP8, 16K ctx)  ←  TrajectoryConverter                   │
│    · 同 trial 连续请求拼接: OpenHands 上下文 mask=0 / 模型输出 mask=1 + logprobs       │
│    ▼                                                                                 │
│  verl GRPO 更新 (64 train NPU, TP4/PP2/EP32) → HCCL 权重同步回 vLLM → 下一 step        │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

## 三、组网视图

```
                        ┌──────────────┐
                        │  Relay 跳板   │ 119.8.234.170
                        │  (运维入口)   │── SSH ──► 全部节点
                        └──────┬───────┘
                               │ 内网 192.168.0.x
        ┌──────────────────────┼──────────────────────┐
        ▼                      ▼                      ▼
┌──────────────┐    ┌──────────────────┐    ┌─────────────────┐
│ 训练集群       │    │ x86 服务器        │    │ (HF 外网下载     │
│ .36 head+train│    │ .100             │    │  经 x86 500M)   │
│ .41~.50 train │◄──►│ trajproxy:12300  │    └─────────────────┘
│   (7节点,64NPU)│    │ postgres:5433    │
│ .17~.48 rollout│    │ OpenHands 容器群  │
│   (4节点,32NPU)│    │ CyberGym:8666    │
│   vLLM:8000   │    │ 源码库/二进制库    │
└───────────────┘    └──────────────────┘
```

**关键链路**：
- OpenHands 容器 → trajproxy（容器网络 `traj-net`，trial_id 路由）
- trajproxy → vLLM（`192.168.0.17:8000`，OpenAI 兼容）
- OpenHands 容器 → CyberGym :8666（`bash ./submit.sh`，内网直连）
- verl → trajproxy PostgreSQL（轨迹拉取，训练侧消费）

## 四、硬件清单

| 角色 | 节点 (192.168.0.x) | 规格 | 用途 |
|------|-------------------|------|------|
| Ray Head + Train | .36 | 8× 910B | 训练编排 + Megatron GRPO |
| Train | .41 .51 .88 .89 .189 .47 .50 | 7×8 = 56 NPU | GRPO 更新 |
| Rollout / 策略端点 | .17 .195 .85 .48 | 4×8 = 32 NPU | vLLM 服务（.17 当前为专用 OpenAI 端点） |
| 正式方案主机 | .100 | x86 32C/64G/492G | trajproxy + OpenHands 沙箱 + CyberGym 判决 |
| Relay | 119.8.234.170 | - | 运维跳板 + 数据中转 |

## 五、已完成的关键能力

| 能力 | 说明 | 文档 |
|------|------|------|
| 多轮 RL 链路 | 七轮迭代（r1-r7）打通 verl tool_agent_loop，首个非零 reward | WORK_SUMMARY.md |
| 官方计分 | final-submission 口径（FAQ Q3），解析轨迹内最后提交结果 | cybergym_reward.py |
| binary-only 判决 | 130GB 官方数据包 + runner 镜像，1507 任务全量可用（99.5% 健康巡检通过） | health_sweep.json |
| 全量源码 | 1507 任务 repo-vul.tar.gz（HF 下载 + 四级完整性校验） | verify_source.py |
| 轨迹库 | v2 基线 1,134 条完整 JSON（全文+分数+细节） | trajectories/ |
| 质量保障 | 逐 Phase 验收门 + 训练期六项持续检查 + preflight 预检 | OPENHANDS_FORMAL_PLAN.md §10 |
| 性能看板 | 五源聚合（步耗时/reward/轨迹/判决/集群） | scripts/perf_dashboard.py |
| 集群补丁 | weight-sync kernel-MoE 布局修复 + master_param fallback（12 节点） | patches/ |

## 六、仓库结构

```
├── OPENHANDS_FORMAL_PLAN.md  # ★ 正式方案（架构/QA体系/5-Phase计划/决策记录）
├── PROGRESS_LOG.md           # ★ 里程碑日志（持续追加）
├── V2_BASELINE_REPORT.md     # v2 基线归档（1,134 轨迹）
├── PLAN.md                   # 历史总体方案（含源码级接口分析）
├── ARCHITECTURE.md           # native 多轮架构 + chat template 参与图
├── THIRD_PARTY.md            # 组件版本锁定 + 集群补丁清单
├── data/                     # parquet 生成 + 任务清单
├── verl_integration/         # 工具层(5工具)/reward/prompt/parser
├── configs/                  # 训练脚本（单轮/多轮）
├── deploy/                   # x86 部署 + 12 节点分发
├── scripts/                  # 预检/看板/压测/校验/巡检
└── patches/                  # 集群热修复 diff（weight-sync / master_param）
```

## 七、快速开始（正式方案部署）

```bash
# 1. x86: trajproxy（已上线）
docker run -d --name traj_db ... postgres:16          # :5433
docker run -d --name traj_proxy ... traj_proxy:latest  # :12300, health=200

# 2. x86: CyberGym 判决（binary 模式）
python3 -m cybergym.server --port 8666 --binary_dir /data/cybergym-server-data

# 3. 集群: 策略端点
docker exec <container> bash /tmp/serve_policy.sh      # .17:8000, TP8

# 4. 验证链路
curl http://192.168.0.100:12300/health                 # trajproxy
curl http://192.168.0.17:8000/v1/models                # 策略端点
```

## 八、设计决策记录

| 决策 | 依据 |
|------|------|
| OpenHands + trajproxy 训练（vs native loop） | 训评同构：模型在评测用的同一 harness 里训练，消除迁移损耗；native 保留为回退 |
| final-submission 计分 | 官方 FAQ Q3 推荐（防 any-of 暴力枚举） |
| binary-only 判决 | 1507 任务免镜像；与 docker 模式判定等价（已对照实测） |
| PoC-as-File + 官方工作区 | 对齐官方 prepare_arvo_files（源码+描述+README+submit.sh） |
| v2 native 作为基线归档 | 正式方案的效果需要参照系；两轴差异（harness×信息量）可归因 |
