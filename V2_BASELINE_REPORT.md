# v2 Native 基线报告（归档）

> 运行期: 2026-08-22 00:01 发射（DeepSeek-V4-Flash-CyberGym-Full-v2）
> 归档时点: 2026-08-22（正式 OpenHands 方案启动前）
> 用户决策: 归档后继续跑至正式方案跑通，届时停掉

## 配置快照

| 项 | 值 |
|----|-----|
| 任务池 | 1507 全量（tasks.json 描述版 level1-desc） |
| batch | 32 任务 × 4 轨迹 = 128 轨迹/step |
| 训练量 | 3 epochs × 47 steps（计划 ~5.6 天） |
| 性能优化 | max_num_seqs=16（64 推理槽）、workers=16 |
| 计分 | 官方 final-submission 口径（轨迹内最后提交结果） |
| 判决 | binary-only 模式（x86 :8666） |
| 上下文 | prompt 4096 / response 4096 |
| 工具 | 3 工具（read_file/submit_poc/execute_code），描述热部署 mid-run |

## 性能数据（v1 → v2 优化验证）

| 指标 | v1 | v2 |
|------|-----|-----|
| 生成阶段/step | 50 min | **33 min**（-34%） |
| 全周期/step | ~90 min | **~60 min** |
| 稳定性 | step1 后中止 | 连续 9+ steps 零异常 |

## 训练数据（归档时点，~9 steps）

```
轨迹库: 1,134 条完整 JSON（含全文+分数）
reward 计算: 1,185 次
分数分布:
  1.6 满分(精确命中):  55 条 (4.9%)
  1.1 崩溃未验fix:      2 条
  0.6 崩错地方:        25 条
  0.1 仅格式(未崩):  1,052 条 (92.8%)

crash 任务榜: arvo:20716×4  arvo:15178×4  arvo:57608×3  arvo:10863×3  arvo:20112×2
```

## 关键发现

1. **均值无上升趋势**（0.12-0.23 波动）——主因：每 step 全新任务（1507 池
   epoch 1 无重访），step 间方差来自任务难度抽签；学习信号存在（组内方差）
   但 9 steps 不足以越过噪声
2. **93% 0.1 分**：desc-only 信息量不足构造精确 PoC——正是转源码+OpenHands
   正式方案的核心动因
3. **轨迹画像**：平均 ~9,200 字符（p50 9,066 / max 14,946），2.1 次提交/轨迹，
   read_file 首轮必调（热部署描述后命中）
4. **满分轨迹样本**（arvo:25121 Leptonica）：无源码时靠注释默写 PIX 结构
   布局构造二进制——"缺源码逼出来的笨办法"，正式方案后变为直接读源码

## 资产移交

| 资产 | 去向 |
|------|------|
| 轨迹库 1,134 条 | 保留（正式方案对照 + 分析素材） |
| final-submission 计分 | 平移进正式方案 Converter |
| 工作区/5 工具语义 | 平移进 OpenHands 任务工作区（官方 prepare_arvo_files） |
| perf_dashboard.py | 持续使用 |
| x86 binary 判决 | 正式方案直接复用 |

## 与正式方案的对比角色

v2 是"native harness + desc-only"基线；正式方案 = "OpenHands + 源码"。
两轴同时变化，若需解耦归因，未来可补"native+源码"中间点（资产都在）。
