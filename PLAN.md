# CyberGym + DeepSeek V4 Flash GRPO 后训练集成方案

## 1. 项目目标

将 [CyberGym](https://github.com/sunblaze-ucb/cybergym)（UC Berkeley Dawn Song 组，ICLR 2026）网络安全漏洞分析评测框架接入当前 DeepSeek V4 Flash GRPO 训练流水线。

**核心思路**：让 DeepSeek Agent 在 CyberGym 环境中分析真实漏洞、生成 PoC、提交验证，用 GRPO 强化学习提升模型的漏洞发现能力。

## 2. 硬件资源

| 角色 | 机器 | 规格 | 用途 |
|------|------|------|------|
| 训练集群 | 12x Ascend 910B (aarch64) | 64 NPUs (8 train + 4 rollout) | verl GRPO 训练 + vLLM 推理 |
| CyberGym Server | x86 服务器 | 32C/64GB/500GB+ | 漏洞验证容器 + FastAPI Server |
| 跳板 | Relay (119.8.234.170, aarch64) | - | SSH 隧道中转 |

## 3. 系统架构

```
训练集群 (910B aarch64, 192.168.0.x)
┌──────────────┐  HCCL broadcast  ┌────────────────┐
│  8 Train 节点 │ ───────────────> │  4 Rollout 节点 │
│  (Megatron)  │   weight sync    │  (vLLM-Ascend) │
│  GRPO update │                  │  Tool Agent Loop│
└──────────────┘                  └───────┬────────┘
                                          │
                                    HTTP POST
                                    /submit-vul
                                          │
                    ┌─────────────────────┘
                    │  cybergym_reward.py
                    │  (custom reward fn)
                    │
                    ▼
┌───────────────────────────────────────────────┐
│  x86 服务器 (32C/64GB)                         │
│                                                │
│  ┌────────────────────┐                        │
│  │  CyberGym Server   │                        │
│  │  FastAPI :8666     │                        │
│  │  - /submit-vul     │──> Docker containers   │
│  │  - /submit-fix     │    n132/arvo:<id>-vul  │
│  └────────────────────┘    n132/arvo:<id>-fix  │
│                                                │
│  数据: ~/cybergym_data/ (subset 10 tasks)      │
└───────────────────────────────────────────────┘
```

### 数据流

1. **Rollout**: verl 的 tool_agent_loop 驱动 DeepSeek 与 CyberGym 多轮交互
2. **Reward**: cybergym_reward.py 从 LLM 输出提取 PoC 代码，HTTP POST 到 CyberGym Server 验证
3. **训练**: GRPO 用 reward 信号更新 DeepSeek 权重
4. **同步**: HCCL broadcast 将更新后的权重同步到 vLLM 推理节点

## 4. 项目结构

```
cybergym_integration/
├── PLAN.md                          # 本文档
├── deploy/
│   ├── setup_x86.sh               # x86 服务器部署脚本
│   └── setup_tunnel.sh            # SSH 隧道配置
├── data/
│   ├── prepare_data.py            # CyberGym tasks → verl parquet
│   └── task_list.json             # Subset 10 任务 ID
├── verl_integration/
│   ├── cybergym_reward.py         # 自定义 reward 函数
│   ├── cybergym_tools.py          # 工具定义 (submit_poc, read_file, exec_code)
│   └── system_prompt.py           # Agent system prompt
├── configs/
│   └── train_cybergym.sh          # 训练启动脚本
└── scripts/
    ├── test_reward.py             # 本地测试 reward
    └── evaluate.py                # 评测 pass rate
```

## 5. 分阶段实施

### Phase 1: x86 基础设施 (Day 1)

```bash
# 在 x86 服务器上执行
bash deploy/setup_x86.sh

# 验证
curl http://localhost:8666/health
```

### Phase 2: 数据准备 (Day 1-2)

```bash
# 在 x86 服务器上
python data/prepare_data.py \
  --cybergym-data ~/cybergym_data \
  --output /data/dataset/cybergym/train.parquet

# 上传到训练集群
scp /data/dataset/cybergym/train.parquet root@192.168.0.36:/data/dataset/cybergym/
```

### Phase 3: Reward 函数 (Day 2-3)

```bash
# 本地测试
python scripts/test_reward.py

# 部署到训练集群
scp verl_integration/cybergym_reward.py root@192.168.0.36:/data/z00666713/deepseek0715/
```

### Phase 4: 多轮 Agent Loop (Day 3-5)

实现 `cybergym_agent` 类型的 tool_agent_loop，注册到 verl。

### Phase 5: 训练 (Day 5-6)

```bash
# 在训练集群 head 节点
bash configs/train_cybergym.sh
```

### Phase 6: 验证 (Day 6-8)

- TensorBoard 监控 reward、loss、Pearson
- 对比训练前后 pass rate

## 6. 关键设计决策

### 6.1 Reward 函数

通过 verl 的 `reward.custom_reward_function.path` 动态加载：

```python
# verl config
reward:
  custom_reward_function:
    path: "/data/z00666713/deepseek0715/cybergym_reward.py"
    name: "compute_score"
```

Reward 信号：
| 条件 | reward |
|------|--------|
| PoC 触发 crash (vul_exit_code != 0) | +1.0 |
| 修复版不 crash (fix_exit_code == 0) | +0.5 |
| 修复版也 crash (fix_exit_code != 0) | -0.5 |
| 超时 (exit_code == 300) | 0.0 |
| 输出了有效 Python 代码 | +0.1 |

### 6.2 多轮交互

使用 verl 的 tool_agent_loop 框架（@register 装饰器注册）：

```
Turn 1: System prompt + 任务描述
Turn 2: LLM 生成 PoC → submit_poc() → exit_code + output
Turn 3: LLM 分析 → 修改 PoC → submit_poc() → 返回
...
Turn N: LLM 确认最终 PoC → submit_poc(final=True)
```

工具定义：
- `submit_poc(code: str)` - 提交 PoC 到 CyberGym
- `read_file(path: str)` - 读取任务文件
- `execute_code(code: str)` - 沙盒执行 Python 代码

### 6.3 网络

SSH 隧道：训练集群 → x86 server，避免 CyberGym 暴露公网

### 6.4 训练参数

基于 train_e4_reduce.sh 的关键改动：
- `data_source`: "cybergym"
- `n_resp_per_prompt`: 4 (从 8 降到 4)
- `max_response_length`: 4096 (工具交互需更长)
- `train_batch_size`: 适配 10 个任务

## 7. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| Reward 稀疏 | GRPO 无法学习 | 选简单任务 + 中间 reward (代码格式) |
| 多轮 token 消耗大 | 训练太慢 | 先单轮简化，后升级多轮 |
| SSH 隧道不稳定 | reward 失败 | 加重试 + fallback reward=0 |
| x86 server 宕机 | 训练中断 | systemd 自动重启 |
