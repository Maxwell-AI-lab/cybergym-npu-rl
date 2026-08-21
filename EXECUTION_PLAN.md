# Phase 1 执行计划（Runbook）

> 目标：跑通 **verl 原生多轮 Agent** CyberGym 训练闭环（模型自主调工具 → CyberGym 验证 → GRPO 更新）。
> 前置已完成：v12 单轮验证 / 多轮代码开发+入库 / 集群补丁入库 / x86 扩容 500G。
> 本文是操作手册：每步给出**精确命令 + 判定标准 + 回退预案**。

---

## 总览：6 步执行链

| 步骤 | 内容 | 依赖 | 预计耗时 | 状态 |
|------|------|------|---------|------|
| S0 | 镜像终验（10 用例 × vul/fix） | 后台拉取完成 | 0（自动） | 🔄 拉取中 |
| S1 | D3 chat template 调查 | 无 | 20 min | 待做 |
| S2 | 重新生成 parquet（10 用例） | relay 数据 + S1 结论 | 30 min | 待做 |
| S3 | 部署 12 节点（含部署脚本） | S2 | 30 min | 待做 |
| S4 | D5 CyberGym 并发压测 | 无（可与 S1-S3 并行） | 30 min | 待做 |
| S5 | 最小链路验证（1 任务 × 1 batch） | S0-S3 | 1-2 h | 待做 |
| S6 | 全量多轮训练 + 监控 | S5 通过 | 3-6 h | 待做 |

---

## S0 镜像终验（后台自动）

后台任务拉完 `oss-fuzz:385167047` 后自动跑 10 用例 × 2 镜像校验并输出 `OK/MISSING` 表。
人工确认口径：

```bash
# relay → x86
ssh root@119.8.234.170 "ssh root@192.168.0.100 'docker images --format \"{{.Repository}}:{{.Tag}}\" | grep -cE \"(arvo|oss-fuzz)\"'"
# 期望: 20
```

**判定**：20/20 全 OK → 继续；385167047 拉取失败 → 训练集降级回 9 用例（task_list.json 去掉该行，其余不受影响）。

---

## S1 chat template 调查（D3，只读）

**问题**：DeepSeek V4 Flash 的 chat template 是否原生支持 `tools` 参数注入？若支持，hermes 格式由模板保证，风险解除；若不支持，靠 system prompt 里的格式示例（已写）。

```bash
# head 节点容器内
ssh root@119.8.234.170 "ssh root@192.168.0.36 \"docker exec cybergym-baseline-zhouzhi python3 -c \\\"
from transformers import AutoTokenizer
tok = AutoTokenizer.from_pretrained('/data_nv1/models/DeepSeek-V4-Flash-DSpark-BF16', trust_remote_code=True)
msgs = [{'role':'user','content':'read the file'}]
tools = [{'type':'function','function':{'name':'read_file','description':'Read task file','parameters':{'type':'object','properties':{'path':{'type':'string'}},'required':['path']}}}]
out = tok.apply_chat_template(msgs, tools=tools, tokenize=False)
print(out[:2000])
\\\"\""
```

**判定**：
- 模板输出含工具定义 + tool_call 格式说明 → ✅ 风险解除（prompt 示例保留作兜底）
- 模板忽略 tools / 报错 → ⚠️ 完全依赖 system prompt 示例；S5 重点观察 `<tool_call>` 是否出现，不出现则切 `multi_turn.format=gpt-oss` 或 `qwen3_coder` 重试

顺带确认 `tokenizer_config.json` 里 `<tool_call>` 相关 token 是否在词表中：

```bash
docker exec ... python3 -c "
tok = AutoTokenizer.from_pretrained(MODEL, trust_remote_code=True)
for t in ['<tool_call>','</tool_call>','<｜tool▁calls▁begin｜>']:
    print(repr(t), tok.convert_tokens_to_ids(t))"
```

---

## S2 重新生成 parquet（10 用例）

**先确认数据源**（relay 上 10 个任务的 description.txt 是否齐全，尤其 385167047）：

```bash
ssh root@119.8.234.170 'for t in 47101 3938 24993 1065 10400 368; do
  ls /data/z00666713/cybergym_data/data/arvo/$t/description.txt >/dev/null 2>&1 && echo "arvo:$t OK" || echo "arvo:$t MISSING"
done; for t in 42535201 42535468 370689421 385167047; do
  ls /data/z00666713/cybergym_data/data/oss-fuzz/$t/description.txt >/dev/null 2>&1 && echo "oss-fuzz:$t OK" || echo "oss-fuzz:$t MISSING"
done'
```

**生成**（本地：从 relay 拉 description 到本地 → 本地 python 生成 → scp 上 head）：

```bash
# 1) 拉数据（只需 description.txt）
mkdir -p ~/cybergym_data/data/{arvo,oss-fuzz}
for t in 47101 3938 24993 1065 10400 368; do
  scp root@119.8.234.170:/data/z00666713/cybergym_data/data/arvo/$t/description.txt ~/cybergym_data/data/arvo/$t.desc
done
# (oss-fuzz 同理，385167047 若 MISSING 则从 task_list.json 移除并同步删除 S0 口径)

# 2) 生成（prompt 已含 Task ID 标记 + hermes 示例）
cd cybergym_integration
python3 data/prepare_data.py \
  --cybergym-data ~/cybergym_data/data \
  --task-list data/task_list.json \
  --output train.parquet --difficulty level1

# 3) 上传 head
scp train.parquet root@119.8.234.170:/data/z00666713/tmp/
ssh root@119.8.234.170 "scp /data/z00666713/tmp/train.parquet root@192.168.0.36:/data/z00666713/tmp/ && \
  ssh root@192.168.0.36 'docker cp /data/z00666713/tmp/train.parquet cybergym-baseline-zhouzhi:/data/dataset/cybergym/train.parquet'"
```

**判定**：parquet 行数 = 10；抽查一行 user 消息含 `Task ID: arvo:` 和 `<tool_call>` 示例。

---

## S3 部署 12 节点

**运行时必需文件**（system_prompt.py 不需要——已烤进 parquet）：

| 文件 | 目标节点 |
|------|---------|
| `verl_integration/cybergym_tools_verl.py` | 全部 12 节点（工具在 rollout 执行，但统一分发防意外） |
| `verl_integration/cybergym_tools.py` | 全部（被前者 import 兜底/工具纯函数） |
| `verl_integration/tool_config.yaml` | 全部 12 节点 |
| `verl_integration/cybergym_reward.py` | head（trainer 侧） |
| `configs/train_cybergym_multiturn.sh` | head |
| `train.parquet` | head（S2 已放） |

写一个 `deploy/deploy_multiturn.sh`（本步骤产出，入库）：

```bash
#!/bin/bash
# 用法: 本地执行。经 relay 中转到 12 节点。
RELAY=root@119.8.234.170
HEAD=36; TRAIN="41 51 88 89 189 47 50"; ROLLOUT="17 195 85 48"
CNAME=cybergym-baseline-zhouzhi
BASE=/data/z00666713/deepseek0715/cybergym_integration

# 1) 推到 relay
scp verl_integration/cybergym_tools_verl.py verl_integration/cybergym_tools.py \
    verl_integration/tool_config.yaml $RELAY:/data/z00666713/tmp/deploy/

# 2) relay → 各节点 scp + docker cp + 清 pycache
for ip in $HEAD $TRAIN $ROLLOUT; do
  ssh $RELAY "ssh root@192.168.0.$ip 'mkdir -p $BASE/verl_integration' && \
    scp /data/z00666713/tmp/deploy/* root@192.168.0.$ip:$BASE/verl_integration/ && \
    ssh root@192.168.0.$ip 'for f in cybergym_tools_verl.py cybergym_tools.py tool_config.yaml; do \
      docker cp $BASE/verl_integration/\$f $CNAME:$BASE/verl_integration/; done; \
      docker exec $CNAME find $BASE -name __pycache__ -exec rm -rf {} + 2>/dev/null; \
      docker exec $CNAME grep -c CyberGymSubmitPocTool $BASE/verl_integration/cybergym_tools_verl.py'" &
done; wait
```

**判定**：12 节点 grep 计数 = 3（三个工具类名）；rollout 任一节点容器内 `python3 -c "import sys; sys.path.insert(0,'/data/z00666713/deepseek0715'); from verl_integration.cybergym_tools_verl import CyberGymSubmitPocTool; print('IMPORT OK')"`。

---

## S4 CyberGym 并发压测（D5，可与 S1-S3 并行）

32 并发 × 各提交 2 个不同 PoC（用 `arvo:3938`——任意输入 crash，走真实容器路径）：

```bash
# relay 或 head 上运行 scripts/stress_cybergym.py（待写，30 行：asyncio + httpx）
python3 scripts/stress_cybergym.py --url http://192.168.0.100:8666 --concurrency 32 --per-worker 2
```

**判定**：
- P99 延迟 < 10s、0 次 429 放弃、x86 `docker ps` 无容器堆积
- 不达标 → CyberGym Server 侧加 `CYBERGYM_RATE_LIMIT_MAX_REQUESTS=500` 或工具侧加信号量（Sem(16)）

---

## S5 最小链路验证（核心关卡）

```bash
# head 容器内
docker exec -it cybergym-baseline-zhouzhi bash
cd /data/z00666713/deepseek0715
CYBERGYM_SERVER_URL=http://192.168.0.100:8666 \
bash cybergym_integration/configs/train_cybergym_multiturn.sh \
  trainer.total_epochs=1 data.train_batch_size=1 actor_rollout_ref.rollout.n=4 \
  2>&1 | tee /tmp/mt_minimal.log
```

**6 项检查（按优先级）**：

| # | 检查 | 命令/方法 | 通过标准 | 不过怎么办 |
|---|------|----------|---------|-----------|
| 1 | 模型发 tool_call | `grep -c '<tool_call>' /tmp/mt_minimal.log` | ≥1 | 强化 prompt / 换 format（S1 结论） |
| 2 | 多轮运转 | `[REWARD-DBG] turns=` 打印值 | 有 >1 的轨迹 | 查 ToolParser 解析、工具结果是否回填 |
| 3 | 工具真实执行 | x86: `tail /data/cybergym/server.out` 看请求 | 有 /submit-vul 记录 | 查 tool_config 加载（S3 判定） |
| 4 | 结果进上下文 | log 中后轮 assistant 文本引用 CRASH/exit_code | 出现 | 查 chat template 的 tool role |
| 5 | reward 正确 | `[REWARD-DBG]` score | 有非零或组内方差 | 查 PoC 提取（reward.py extract） |
| 6 | 训练健康 | 进程正常退出、无 NaN | step:1 完成 | 按 v12 经验查 NPU/HCCL |

**通过标准**：#1-#4 全过 = 多轮链路通（可提前报捷）；#1-#6 全过 = 进入 S6。

---

## S6 全量多轮训练

```bash
docker exec -it cybergym-baseline-zhouzhi bash
CYBERGYM_SERVER_URL=http://192.168.0.100:8666 \
bash cybergym_integration/configs/train_cybergym_multiturn.sh \
  trainer.total_epochs=5 2>&1 | tee /data/z00666713/deepseek0715/logs/mt_full_$(date +%m%d_%H%M).log
```

**监控**（每 10 min）：

| 指标 | 来源 | 健康值 |
|------|------|--------|
| `[REWARD-DBG]` turns 分布 | 训练 log | 平均 ≥2（模型在迭代） |
| reward mean/std | log / console | std>0（GRPO 有梯度） |
| infra error 比例 | REWARD-DBG 里 exit=-1 | <5% |
| crash rate 变化 | tool metrics / server.out | 相对首 step 有变化 |
| NPU 显存/温度 | `npu-smi info`（head 抽查） | 稳定不涨 |
| x86 容器堆积 | `docker ps | grep -c arvo` | 无残留 |

**停止条件**：连续 2 step 全 group std=0 → 停，分析 reward 链路；显存 OOM → `max_response_length` 降至 3072 重试。

**产出物**：训练 log + reward 统计 + 首尾 step 轨迹抽样对比 → 写入 `reports/phase1_result.md`（入库）。

---

## 成功标准（Phase 1 Exit）

1. ✅ 轨迹含真实工具调用（S5 #1/#3）
2. ✅ 平均 turns ≥ 2，模型基于 crash 结果迭代（S5 #2/#4）
3. ✅ reward 组内有方差（S5 #5 / S6 监控）
4. ✅ 连续 10+ steps 稳定（S6）
5. ✅ crash rate 相对基线有变化（S6 首尾对比）

---

## 人员分工建议（如多人）

- A（集群）：S1、S3、S5、S6
- B（x86/数据）：S0 确认、S2、S4
- 全部产出（脚本/报告/补丁）→ git 提交 `cybergym-npu-rl`
