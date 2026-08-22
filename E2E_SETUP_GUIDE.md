# CyberGym-E2E 评测环境搭建与运行指南

> 状态: 数据集下载中（78%），本文档为就绪后的执行指南
> 前置文档: CYBERGYM_E2E_ANALYSIS.md（深度分析）/ CYBERGYM_E2E_EVALUATION_PLAN.md（评估方案）

---

## 一、环境总览

```
x86 服务器 (192.168.0.100, 32C/64GB/1TB)
├── /data/cybergym-e2e/           ← E2E 官方仓库（git clone）
│   ├── projects/                  ← 139 个项目定义（920 任务）
│   ├── scripts/                   ← runner + validator
│   └── data/                      ← HF 数据集（下载中）
│       └── projects/<proj>/<task>/
│           ├── src.tgz            ← 源码快照
│           ├── poc.bin            ← ground-truth PoC
│           └── crash.log          ← 崩溃报告
│
├── /data/e2e_venv/               ← Python 虚拟环境（huggingface_hub 等）
│
├── Docker 镜像 (30 个)            ← ✅ 已全部就位
│   ├── base-builder ×2            ← OSS-Fuzz 通用构建镜像
│   └── n132/arvo:*-fix ×28        ← 项目专用构建镜像
│
└── LLM 端点                       ← 待配置（指向集群 vLLM）

集群侧 (12×910B)
└── vLLM 推理服务                   ← 提供策略模型的 OpenAI 兼容 API
```

## 二、搭建步骤（数据集下载完成后执行）

### Step 1: 安装 E2E 依赖

```bash
# 在 x86 上
cd /data/cybergym-e2e
/data/e2e_venv/bin/pip install tomli tomli_w httpx docker
# 注意: 不要装在系统 Python（根分区满），全部用 /data/e2e_venv

# 系统级配置
sudo sysctl -w vm.mmap_rnd_bits=28     # ASLR（sanitizer 兼容）
sudo apt-get install -y sudo git        # 容器内需要
```

### Step 2: 验证数据完整性

```bash
/data/e2e_venv/bin/python /tmp/verify_e2e.py
# 预期输出: ✅ ALL CLEAN
# 五级校验: manifest → gzip → siblings → size → docker images
```

### Step 3: 配置 LLM 端点

```bash
# 方案 A: 用集群 vLLM（需要先起推理服务）
export OPENAI_BASE_URL="http://192.168.0.36:8000/v1"  # 集群 head
export OPENAI_API_KEY="EMPTY"                          # vLLM 默认不校验
export LLM_MODEL="deepseek-v4-flash"

# 方案 B: 用独立推理节点（不干扰训练）
# 在某个 rollout 节点起 vLLM serve，暴露 OpenAI 端点
```

### Step 4: 单任务试跑

```bash
cd /data/cybergym-e2e
# 使用 Claude Code 式的 agent（不需要安装 OpenHands）
python3 scripts/run_agent.py wasm3/arvo_33318 --mode e2e

# 或使用 OpenHands
python3 scripts/run_agent.py wasm3/arvo_33318 --mode e2e --agent openhands
```

### Step 5: 批量评测

```bash
# 选取子集先跑（推荐先 50-100 个）
head -50 scripts/tasks.txt > scripts/tasks_subset.txt
MODE=e2e MAX_PARALLEL=4 bash scripts/batch_run.sh scripts/tasks_subset.txt

# 全量 920 任务
MODE=e2e MAX_PARALLEL=4 bash scripts/batch_run.sh scripts/tasks.txt
```

## 三、组件清单与状态

| 组件 | 位置 | 状态 | 说明 |
|------|------|------|------|
| E2E 源码 | /data/cybergym-e2e/ | ✅ | git clone，含 920 任务定义 |
| HF 数据集 | /data/cybergym-e2e/data/ | 🔄 78% | src.tgz + poc.bin + crash.log |
| Docker 镜像 | x86 Docker | ✅ 34 个 | base-builder ×2 + arvo fix ×28+ |
| Python 环境 | /data/e2e_venv/ | ✅ | huggingface_hub 已装 |
| E2E 依赖 | 待装 | ⏳ | tomli, httpx, docker 等 |
| LLM 端点 | 集群 vLLM | ⏳ | 需暴露 OpenAI 兼容 API |
| 校验脚本 | /tmp/verify_e2e.py | ✅ | 五级完整性校验 |

## 四、E2E 与现有 CyberGym 的资产关系

```
共用（不冲突）:
  · x86 Docker + 磁盘 + 带宽
  · 集群 vLLM 推理（可复用同一端点）
  · trajproxy（如果 RL 训练需要轨迹捕获）

独立（并行运行）:
  · CyberGym Server :8666 ← 原版 CyberGym RL 训练用
  · E2E validate.py    ← E2E 评测用（容器内自主调用）
  · 两套任务数据完全独立
```

## 五、评测模式选择

| 模式 | Agent 拿到什么 | Agent 产出什么 | 验证方式 |
|------|--------------|--------------|---------|
| **e2e** | 只有源码 | PoC + 补丁 | 四阶段全验证 |
| **patch-only** | 源码 + PoC + crash.log | 补丁 | 跳过 S1（PoC 已给） |

**推荐**：先用 `patch-only` 模式跑基线（更容易出结果），再用 `e2e` 模式测完整能力。

## 六、结果解读

```
S1: Agent PoC 崩溃了（证明 bug 存在）
S2: Agent 补丁阻止了崩溃（证明补丁有效）
S3: 开发者测试通过（证明没修坏别的东西）★ 主指标
S4: 官方 PoC 也不崩了（证明修的是目标 bug）★ 精确指标

论文参考值:
  GPT-5.4:           Patch-only 87.1% | S3 22.2%
  Opus 4.6 (无限预算): Patch-only 85.8% | S3 26.2%
```

## 七、预计资源消耗

| 资源 | 单任务 | 920 任务全量 |
|------|--------|-------------|
| Agent 容器 | 1 个（~2-4GB 内存） | 920 个（串行或 4 并发） |
| 验证容器 | 4 个/任务（每阶段一个） | 3680 个 |
| 时间 | ~90 分钟 | 920 × 90min ÷ 4 并发 ≈ 14.4 天 |
| LLM 调用 | 视 agent 迭代次数 | — |
| 磁盘 I/O | 编译产物（容器内） | 容器销毁即释放 |
