# 环境与物料清单（版本溯源文档）

> 记录日期: 2026-08-22
> 目的: 完整记录所有软件版本、镜像来源、硬件配置，便于复现和排障

---

## 1. 硬件清单

### 训练集群（12 节点 Ascend 910B, aarch64）

| 节点 | IP | NPU | 角色 |
|------|-----|-----|------|
| head | 192.168.0.36 | 8× 910B (64GB/卡) | Ray head + Megatron 训练 |
| train-1 | 192.168.0.41 | 8× 910B | 训练 |
| train-2 | 192.168.0.51 | 8× 910B | 训练 |
| train-3 | 192.168.0.88 | 8× 910B | 训练 |
| train-4 | 192.168.0.89 | 8× 910B | 训练 |
| train-5 | 192.168.0.189 | 8× 910B | 训练 |
| train-6 | 192.168.0.47 | 8× 910B | 训练 |
| train-7 | 192.168.0.50 | 8× 910B | 训练 |
| rollout-1 | 192.168.0.17 | 8× 910B | vLLM 推理 |
| rollout-2 | 192.168.0.195 | 8× 910B | vLLM 推理 |
| rollout-3 | 192.168.0.85 | 8× 910B | vLLM 推理 |
| rollout-4 | 192.168.0.48 | 8× 910B | vLLM 推理 |

**合计**: 96 NPU（64 训练 + 32 推理）

### x86 服务器

| 项 | 值 |
|----|-----|
| IP | 192.168.0.100 |
| CPU | 32C |
| 内存 | 64GB |
| 磁盘 | /data 492GB（vdb, ext4） |
| 架构 | x86_64 |
| OS | Ubuntu 24.04 |
| 带宽 | 500Mbps（已扩容） |

### Relay 跳板

| 项 | 值 |
|----|-----|
| IP | 119.8.234.170 |
| 架构 | aarch64 |
| 用途 | SSH 中转、数据下载、HuggingFace 访问 |

---

## 2. Docker 镜像清单

### 集群容器（所有 12 节点）

| 镜像 | 版本 | 用途 | 来源 |
|------|------|------|------|
| cybergym-baseline | - | 训练/推理统一容器 | 华为云预置 |

### x86 服务器

| 镜像 | 版本 | 大小 | 用途 | 来源 |
|------|------|------|------|------|
| cybergym/oss-fuzz-base-runner | latest | 2.03GB | binary 模式统一 runner | Docker Hub |
| n132/arvo:\<task_id\>-vul/fix | 各任务 | 15-70GB/个 | docker 模式验证（已弃用） | Docker Hub |
| traj_proxy | latest | 1.13GB | 轨迹捕获代理 | 本地构建 |
| postgres | 16 | ~400MB | trajproxy 数据库 | Docker Hub |
| ghcr.io/all-hands-ai/runtime | latest | ~2-4GB | OpenHands 沙箱 | GitHub Container Registry |

### 镜像拉取记录

| 镜像 | 拉取日期 | 方式 | 备注 |
|------|---------|------|------|
| cybergym/oss-fuzz-base-runner | 2026-08-21 | docker pull | 直接拉取成功 |
| n132/arvo 系列 (20个) | 2026-08-20 | docker pull | 6 个 fix 超时后补拉 |
| traj_proxy | 2026-08-22 | docker build | 从 GitHub 源码构建 |
| postgres:16 | 2026-08-22 | docker pull | 标准 Docker Hub |
| ghcr.io/all-hands-ai/runtime | 2026-08-22 | docker pull | ghcr.io（docker.all-hands.dev DNS 不可达） |

---

## 3. 软件版本

### 训练容器内

| 软件 | 版本 | 路径 | 用途 |
|------|------|------|------|
| Python | 3.12.13 | /usr/local/python3.12.13 | 运行时 |
| verl | commit 809f2d8f | /workspace-verl/verl | 训练框架 |
| vllm-ascend | commit c2670ba3f (v0.25.1rc) | /workspace-verl/vllm-ascend | NPU 推理 |
| MindSpeed-LLM | commit 99f7fc1d | 容器内 | Megatron 昇腾后端 |
| megatron-core | 0.12.1 (pip) | /workspace-verl/verl/megatron | 分布式优化器 |
| Ray | 容器内置 | - | 分布式调度 |
| CANN | 9.0.0 | /usr/local/Ascend | NPU 驱动/运行时 |
| HCCL | 容器内置 | - | NPU 通信库 |

### 模型

| 项 | 值 |
|----|-----|
| 名称 | DeepSeek V4 Flash (DSpark variant) |
| 路径(训练) | /data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16 |
| 路径(deploy) | /data/model/DeepSeek-V4-Flash-bf16-deploy |
| 精度 | BF16 |
| 参数量 | MoE 256 experts, top-6 routing |
| 上下文 | 128K (训练用 8K) |
| 并行约束 | **必须多节点 EP=32**（单节点 TP8 必 OOM） |

### x86 服务器

| 软件 | 版本 | 安装方式 |
|------|------|---------|
| Python | 3.12.3 (系统) | apt |
| Docker | 29.1.3 | apt |
| PostgreSQL | 16 (Docker) | docker run |
| trajproxy | 源码构建 | docker build |

### 训练并行配置（已验证）

| 参数 | 值 | 说明 |
|------|-----|------|
| train_tp | 4 | 训练张量并行 |
| train_pp | 2 | 训练流水线并行 |
| train_ep | 32 | 训练专家并行 |
| gen_tp | 8 | 推理张量并行（每节点） |
| gen_dp | 4 | 推理数据并行（4节点） |
| gen_ep | 32 | 推理专家并行（跨32卡） |
| dspark | num_speculative_tokens=5 | 投机解码 |

---

## 4. 数据集清单

| 数据 | 位置 | 大小 | 任务数 | 来源 |
|------|------|------|--------|------|
| tasks.json (元数据) | relay:/data/z00666713/cybergym_data/ | 1.8MB | 1507 | HF: sunblaze-ucb/cybergym |
| 漏洞描述 | 同上 data/{arvo,oss-fuzz}/\<id\>/description.txt | ~100KB/任务 | 1507 | 同上 |
| 源码包 repo-vul.tar.gz | x86:/data/cybergym_src/arvo/<id>/ | ~36GB | 1368 (arvo) | HF 下载 |

**⚠️ data_dir 路径**: `/data/cybergym_src`（注意：不要加 `/data` 后缀！）
已修复 HF 下载时的多余 `data/` 层级。cybergym `generate_task()` 期望 `data_dir` 直接包含 `arvo/` 目录。
| 源码包 (x86) | x86:/data/cybergym_src/ | ~36GB | 待传输完成 | relay→x86 tar |
| binary 判决数据 | x86:/data/cybergym-server-data/ | 130GB | 1507 | cybergym-server-data.7z |
| runner 镜像 | x86:Docker | 2.03GB | - | Docker Hub |

### 训练 parquet

| 文件 | 任务数 | 位置 | 用途 |
|------|--------|------|------|
| train.parquet | 10 | head:/data/dataset/cybergym/ | v2 基线 |
| train_100.parquet | 100 | 同上 | S7 计划（未使用） |
| train_full.parquet | 1507 | 同上 | v3 正式训练 |

---

## 5. 网络配置

### Docker 网络

| 网络 | 用途 | 子网 |
|------|------|------|
| traj-net | trajproxy + postgres 通信 | bridge |
| host | 集群容器（全部） | 宿主机网络 |
| none | CyberGym 验证容器 | 断网隔离 |

### 关键端口

| 端口 | 服务 | 节点 | 协议 |
|------|------|------|------|
| 8666 | CyberGym Server | x86 | HTTP |
| 12300-12304 | trajproxy workers | x86 | HTTP |
| 5433 | PostgreSQL (trajproxy) | x86 | TCP |
| 9090 | vLLM OpenAI API (rollout) | rollout 节点 | HTTP |
| 6766 | Ray 集群 | head | TCP |

### DNS 已知问题

| 域名 | 状态 | 影响 | 解决 |
|------|------|------|------|
| docker.all-hands.dev | NXDOMAIN | 无法拉 OpenHands 官方镜像 | 用 ghcr.io/all-hands-ai/runtime 替代 |
| huggingface.co | relay 可达 / x86 间歇 | 源码下载 | x86 用 curl 直连（500M 带宽） |

---

## 6. 集群补丁（已应用到 12 节点）

| 补丁 | 文件 | 效果 | 仓库 |
|------|------|------|------|
| 0001-kernel-moe-weight-sync | vllm_ascend/models/deepseek_v4.py | 修复 MoE kernel 布局 weight sync crash | patches/0001-*.patch |
| 0002-master-param-fallback | megatron/core/optimizer/distrib_optimizer.py | 修复 CPU offload 下 master_param KeyError | patches/0002-*.patch |
| 0003-vllm-server-port | verl/workers/rollout/utils.py | port=0 → VLLM_SERVER_PORT 环境变量 | deploy/patch_vllm_port.sh |
| register_dsv4.py | /data/z00666713/deepseek0715/ | DS4 model_type 幂等注册 | patches/register_dsv4.py |

---

## 7. 关键配置文件

| 文件 | 位置 | 用途 |
|------|------|------|
| train_cybergym_multiturn.sh | configs/ | verl 训练启动脚本 |
| tool_config.yaml | verl_integration/ | 工具注册（5 工具） |
| cybergym_reward.py | verl_integration/ | final-submission 计分 |
| config.yaml | x86:/data/trajproxy/dockers/compose/configs/ | trajproxy 配置 |
| sandbox_hosts.yaml | （规划中） | OpenHands 沙箱主机注册 |

---

## 8. 环境变量

### 训练脚本

| 变量 | 值 | 用途 |
|------|-----|------|
| CYBERGYM_SERVER_URL | http://192.168.0.100:8666 | 判决服务地址 |
| CYBERGYM_API_KEY | cybergym-030a0cd7-... | 判决服务认证 |
| VLLM_SERVER_PORT | 9090 | vLLM HTTP 固定端口（补丁 0003） |
| CYBERGYM_MAX_CONCURRENT | 32 | 判决并发上限 |

### trajproxy 容器

| 变量 | 值 |
|------|-----|
| DATABASE_URL | postgresql://traj:trajpass123@traj_db:5432/traj_proxy |
| PYTHONUNBUFFERED | 1 |
