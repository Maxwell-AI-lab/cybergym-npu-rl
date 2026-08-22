# 正式 RL 训练完整实施计划

> 目标架构：常驻训练作业 + 作业内引擎采集 + 每步权重自动同步
> 最终验收：无人值守 N≥2 轮闭环、Pearson≥0.99、判分正确入组、性能最优配置

## 总览

```
Phase 0  环境对齐          ── 集群清场重拉（前置，~30min）
Phase 1  性能与图模式      ── 正式训练前配置评估（CKSUM/图模式/训练提速, ~0.5天）
Phase 2  Pearson 达标      ── 零截断对照 → 残差定位（与 Phase 1 并行排队, ~2h）
Phase 3  常驻架构开发      ── uid补丁/阻塞Dataset/编排器v2（~0.5天）
Phase 4  首个自动闭环      ── 2 轮无人值守验收（~2h）
Phase 5  正式训练          ── N=10轮 × 10任务 × 4agent + 监控（~1天机器时）
```

## Phase 0: 环境对齐（前置）

| 步骤 | 内容 | 验证 |
|---|---|---|
| 0.1 | 12 节点 cleanup_ray.sh 清场 | 各节点 CLEAN-OK |
| 0.2 | head 50 + 11 worker 重拉 ray | ray status: 12 Active, 96 NPU |
| 0.3 | x86 侧检查 trajproxy/discovery/CyberGym server 在线 | /v1/models 可达、:8666 健康 |

## Phase 1: 性能与图模式（正式训练前完成）

| # | 实验 | 改动 | 验证指标 |
|---|---|---|---|
| 1.1 | CKSUM 埋点门控 | deepseek_v4.py 等处 CKSUM 块加 env 开关（默认关），12 节点部署 | update_weights 87s→? ；日志无刷屏 |
| 1.2 | 图模式开启 | enforce_eager=False + ray_start_fixed 去 TORCHDYNAMO_DISABLE + cudagraph_mode=FULL_DECODE_ONLY | 引擎日志出现 graph capture；采集吞吐 |
| 1.3 | 训练提速扫描 | ppo_micro_batch 1→2、dynamic_bsz、use_remove_padding | update_actor 529s→?；NPU 峰值 |
| 1.4 | HCCL 传输检查 | 确认 socket vs RDMA，若 socket 评估启用 roce | 同步带宽 |

方法：每配置单步作业（复用现有 dump，无采集），读 timing_s/*。
产出：最优配置表，进 Phase 5。

## Phase 2: Pearson≥0.99 达标

| 步骤 | 内容 | 判定 |
|---|---|---|
| 2.1 | 零截断对照实验（drop-overlong 64 批，已备好） | Pearson 0.957→? 截断因素占比 |
| 2.2 | 残差定位（若<0.99）：DSpark spec 对 logprob 污染、top_k=50 logits 重整化——单请求对照（top_k=-1 vs 50、spec on/off） | 找到并消除 |
| 2.3 | 常驻架构首轮新鲜数据复检（采集与训练同权重） | ≥0.99 硬门槛 |

## Phase 3: 常驻架构开发（D1 数据门控）

| 步骤 | 内容 | 接口验证 |
|---|---|---|
| 3.1 | uid 覆盖补丁：union_numpy_dict 中 uid 冲突时取 gen(dump) 侧 | 单测：构造冲突 union 不炸 |
| 3.2 | BlockingRLHFDataset：__getitem__ 前等 genstep_k 标记文件；N×64 占位 parquet（内容无关） | 本地单测：文件出现前后行为 |
| 3.3 | RolloutSkip 逐步加载对齐：genstep_k 与第 k 步对应 | dry-run 日志确认 |
| 3.4 | 编排器 v2：探引擎(:9090)→x86 collect_batch→converter→prep 写 genstep_k→tail 日志等 step:k→下一轮 | 各段手动触发通过 |
| 3.5 | 竞态防护：step:k 后等 update_weights 完成再采集（日志特征+健康探测+停顿） | 无半新半旧权重采集 |

## Phase 4: 首个自动闭环（验收门）

- 4.1 无人值守连续 2 轮：编排器自动驱动，无人工干预
- 4.2 验收清单：
  - [ ] 每轮 Pearson≥0.99（rollout_corr 指标自动读取）
  - [ ] reward 正确流入（critic/score 分布）
  - [ ] GRPO 组内方差>0（同任务≥2 agent 不同判分）
  - [ ] 第 2 轮采集确实用上第 1 轮更新后的权重
- 4.3 失败迭代修复

## Phase 5: 正式训练

- 5.1 N=10 轮 × 10 任务(官方子集) × 4 agent/任务，Phase 1 胜出配置
- 5.2 每轮自动记录：reward 曲线 / Pearson / entropy / response_length
- 5.3 周期 eval（留出任务集 pass rate）
- 5.4 归档：PROGRESS_LOG + GitHub + 镜像 tar 收尾

## 并行事项

- 镜像 tar.gz 导出完成检查（v31-openhands-t5）
- level 逐级对比测试（全链稳定后最后执行）

## 风险与对策

| 风险 | 对策 |
|---|---|
| 常驻作业中途崩溃丢失进度 | 首批按小时级跑可接受；天级前加轻量周期存档 |
| 采集期间权重半同步 | 编排器串行化+健康探测 |
| 引擎放置漂移 | 发现代理已解决 |
| Pearson 不达标 | Phase 2 分解实验闭环后再进 Phase 4 |
