# 第三方组件与集群补丁清单

本项目依赖的核心组件源码位置、精确版本、以及**仅存在于集群节点上的补丁**（已抢救为 patch 文件纳入本仓库）。

## 1. 组件清单

| 组件 | 本地源码位置 | 精确版本 | 集群部署位置 | 用途 |
|------|-------------|---------|-------------|------|
| **verl** | `../server_code/verl/` | commit `809f2d8f`（与集群逐字节一致） | 容器 `/workspace-verl/verl` | 训练框架：GRPO、tool_agent_loop、BaseTool、reward 加载 |
| **vllm-ascend** | `../server_code/vllm-ascend/` | commit `c2670ba3f`（releases/v0.25.1rc，与集群一致） | 容器 `/workspace-verl/vllm-ascend` | 910B 推理后端（rollout 节点 vLLM） |
| **megatron-core** | （pip 包，无本地 clone） | `0.12.1` | 容器 `/workspace-verl/verl/megatron/` | Megatron 分布式 optimizer（打补丁 0002） |
| **CyberGym** | `../server_code/cybergym/` | commit `7656b71`（官方 sunblaze-ucb/cybergym） | x86 pip `cybergym==0.2.0`，数据 `/data/cybergym/` | 验证服务（vul/fix 双容器裁判） |
| **MindSpeed-LLM** | `../server_code/MindSpeed-LLM/` | commit `99f7fc1d`（gitcode.com/ascend） | 容器 mindspeed_llm（Megatron 昇腾后端） | 训练并行层 |
| DeepSeek V4 Flash | `/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16` | — | 集群共享存储 | 训练模型 |

> `../server_code/*` 各自是独立 git clone（父仓库 .gitignore 标注为子仓库），commit 已锁定到与集群一致。
> **trajproxy**（versatile-ai/trajproxy）已做完整源码分析（OpenAI 兼容轨迹捕获代理），但本项目**未使用**——仅在引入外部黑盒 Agent 时需要，见 PLAN.md 选型记录。

## 2. 集群补丁（patches/）

以下补丁**只存在于集群容器内**（12 节点手工分发生效，v12 已验证），现已导出为标准 diff 纳入版本管理。重建集群时按顺序应用：

### 0001-vllm-ascend-deepseek_v4-kernel-moe-weight-sync-fix.patch

- **目标文件**: `vllm_ascend/models/deepseek_v4.py`
- **问题**: vllm-ascend 的 PWAL（process_weights_after_loading）把 MoE 权重转成 kernel 布局（w2 `[8,4096,2048]→[8,2048,4096]`），但训练侧 HCCL 同步来的权重按 vLLM 布局的 shard_dim 切分，`copy_d2d` shape 不匹配直接 crash
- **修复**: 加载前检测实际布局（比较 w2 两个维度），若处于 kernel 布局则先把参数转置回 vLLM 布局，保证 weight_loader 的 narrow 语义正确
- **应用**: `cd vllm-ascend && git apply 0001-*.patch`（12 节点容器内，应用后删 `__pycache__`）

### 0002-megatron-core-0.12.1-distrib-optimizer-master-param-fallback.patch

- **目标文件**: `megatron/core/optimizer/distrib_optimizer.py`（megatron-core 0.12.1）
- **问题 1**: `use_precision_aware_optimizer=True` + CPU offload（HybridDeviceOptimizer）组合下 optimizer state 无 `master_param`，`tensors.pop("master_param")` 抛 KeyError
- **修复 1**: fallback 到 `sharded_model_param`（bf16 分片，与 verl 权重同步精度一致）
- **问题 2**（补丁中一并保存）: HybridDeviceOptimizer 要求参数为 leaf tensor，切片视图导致优化器初始化异常
- **修复 2**: 非 leaf 参数 `clone().detach().requires_grad_()` 物化
- **原版来源**: PyPI `megatron-core==0.12.1` tar 包（本地 diff 基准）

### register_dsv4.py

- DeepSeek V4 Flash 的 `model_type` 未进 transformers 注册表，训练脚本启动前先 `import register_dsv4` 幂等注册（读模型目录 config.json 的 auto_map）。

## 3. 部署状态速查

```
12× 910B 节点（.36 head + 7 train + 4 rollout）
  容器 cybergym-baseline-zhouzhi
  ├─ verl @809f2d8f            ← 未改
  ├─ vllm-ascend @c2670ba3f     ← + patch 0001
  └─ megatron-core 0.12.1       ← + patch 0002

x86 (192.168.0.100, 492G)
  ├─ CyberGym Server :8666 (pip cybergym==0.2.0)
  ├─ SQLite /data/cybergym/poc.db
  └─ 10 任务 × vul/fix Docker 镜像（n132/arvo:*, cybergym/oss-fuzz:*）
```
