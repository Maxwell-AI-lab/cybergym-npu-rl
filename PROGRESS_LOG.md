# 进展日志（PROGRESS LOG）

> 纪律：每个里程碑/异常/决策追加一节；每次会话收尾 commit+push。
> 完整方案见 OPENHANDS_FORMAL_PLAN.md；v2 基线见 V2_BASELINE_REPORT.md。

## 2026-08-21（深夜）多轮 RL 链路打通日

- **S5 七轮迭代（r1-r7）**跑通 verl 原生多轮 Agent 全链路：
  - r1 发现模型 XML 方言 → r2 残缺格式 → r3 定位真凶（agent loop 配置路径
    `+agent.*` 静默失败）→ r4 包路径 → r5 首个完整训练闭环（100% 干净退出）
  - r6 确证工具执行+结果回填（has_tool_result=True）；发现 localhost 计分坑
  - r7 首个非零 reward（mean 0.44/max 1.6，满分轨迹 .file 4294967289 实证）
- 计分升级：官方 final-submission 口径（解析轨迹内最后提交结果，修正 DSML 漏计）
- 规模化解锁：官方 130GB binary 数据包 → binary-only 判决（1507 全量）
- 全量正式训练 v1 发射（1507×3epochs）→ step1 数据驱动优化 →
  **v2 发射**（max_num_seqs 16 提速 34% + 轨迹全量落盘激活）
- 工具异步化修复、并发信号量、preflight 预检体系、perf_dashboard 落地

## 2026-08-22（晨）

- **用户决策：转正式方案**（OpenHands + trajproxy + verl 全链路）
- 官方对齐调研完成：agent-examples 仓库 / arvo_task.py 任务语义 /
  FAQ Q3 计分 / README+submit 模板 / CYBERGYM_EVAL_INFO（顶尖 ~20%）
- v3 native 官方对齐工具层完成（write_file/execute_command/file_path 提交）
  → 正式方案启动后作为资产平移，v3 发射取消
- trajproxy 克隆至 x86，精简部署进行中（postgres 无 compose 插件改裸 run）
- 源码下载：hub 限流卡死 → 串行 curl → **x86 500M 带宽冲刺**（13.5 个/分）
  → 216/215 完成 → 合并回 relay 主库（后台）+ 四级校验待跑
- **用户三条指令**：小并发起步后扩容 / 小批量任务验证 / v2 归档待停
- 文档体系落地：OPENHANDS_FORMAL_PLAN.md（含 QA 体系）/ V2_BASELINE_REPORT.md /
  本日志

### 当前在途
- [T1] trajproxy 部署：postgres 容器（裸 docker run 进行中）
- [源码] relay 主库合并（~90%）
- [v2] 继续跑基线（9+ steps，1,134 轨迹，正式方案跑通后停）

### 下一步（按 OPENHANDS_FORMAL_PLAN 执行）
1. T1 完成：postgres + trajproxy 容器 health 200
2. T2：OpenHands 构建锁定 + 单任务接线
3. 源码合并完 → verify_source.py 四级校验 → 任务工作区生成

### T1 完成（2026-08-22 09:50）
- traj_db（postgres:16, :5433, 数据卷持久化）pg_isready ✓
- traj_proxy（2 workers, :12300-12304）health 200 ✓
- 踩坑: 模板 config 的 database.url 指向不存在的 `db` 主机名（name resolution
  报错根因）→ 改指 traj_db；x86 无 compose 插件 → 裸 docker run
- DS4 tokenizer 挂载 /app/models/dsv4 ✓（PyTorch 缺失警告为 tokenizer-only 正常态）
- 模型注册成功: deepseek-v4-flash / TITO=true / tokenizer_path 正确
- 测试请求全链路直达后端转发（占位 URL 连接失败=预期），T2 接真 vLLM 即闭环

### v3 发射（2026-08-22 10:30）
- 用户确认发射；v3 = 多节点 rollout（TP8/DP4/EP32）同时充当:
  ① 正式训练  ② trajproxy 的策略端点（vLLM :9090）
- 关键修正记录: 单节点 TP8 serve 必 OOM（256 experts 需 EP=32 分散 32 卡）
  → 用 verl 训练基础设施做策略端点是唯一正确路径
- trajproxy 后端已更新: http://192.168.0.17:9090/v1
- 9090 就绪监视器已挂; 就绪后执行 T2 接线验证

### 端口补丁修复（2026-08-22 12:30）
- v3 第一次启动 crash: NameError 'os' is not defined
  → 端口补丁用了 os.environ 但忘了 import os
- 12 节点已补 import os，v3 重启
- 源码 x86 1368/1368 全量就位 ✅
- OpenHands runtime 镜像 ghcr.io 拉取中

### 关键突破（2026-08-22 15:40）

**全链路打通验证成功**:
```
trajproxy(:12300) → vLLM(.17:9090, TP8/DP4/EP32 多节点)
  → 模型生成回复 → 轨迹捕获(token级) → PostgreSQL 入库 ✓
```

**基础设施全部就绪**:
- OpenHands 官方 runtime 镜像 (ghcr.io, 7.24GB) → x86 ✅
- 源码 1368 任务 → x86 ✅
- trajproxy (TITO 模式) → 运行中 ✅
- vLLM 多节点策略端点 (:9090) → 运行中 ✅
- CyberGym 判决 (:8666, binary模式) → 运行中 ✅
- PostgreSQL (4张表) → 就绪 ✅
- 官方任务工作区 (gen_task格式) → 就绪 ✅

**技术攻关记录**:
- 镜像下载: GitHub CDN 三台机器都超时 → wget 逐层断点续传成功
- vLLM HTTP 暴露: port=0 随机 → 补丁固定 9090 + 保持节点 IP 绑定
- trajproxy 数据库: 手动建 4 张表 (model_registry + request_metadata
  + request_details_active + r3_blob_refs), 列类型 BIGINT[] 非 JSONB
- 模型名匹配: trajproxy 的 model_name 需与 vLLM 的 served-model-name 一致

**当前**: OpenHands 官方版从源码构建中 (pinned commit 35b381f)

### OpenHands E2E 调试记录（2026-08-22 16:20）

**已攻克**:
- OpenHands 官方 runtime 0.33-nikolaik 精确版本下载成功（wget 逐层 2.2GB）
- OpenHands controller 从 pinned commit 构建成功
- litellm provider 路由: `base_url`（非 `api_base`）字段名是关键
- OpenHands → trajproxy: 路由打通（Anthropic → OpenAI 兼容 → trajproxy）
- 容器启动 → agent 读取任务 → 调用 LLM 全链路走到 vLLM 连接

**当前**: v6 训练重启中（vLLM 端口 9090 等 20 分钟加载完成后 E2E 自动闭环）

### 🎉 OpenHands E2E 成功（2026-08-22 17:15）

**完整链路首次闭环**:
```
OpenHands Agent (CodeActAgent) → trajproxy(:12300) → 自动发现代理(x86:9090)
  → vLLM(.17:9090, 32K context, TP8/DP4/EP32) → 模型推理 → 回复
  → Agent 在容器内执行命令（10轮迭代）→ submit.sh → CyberGym 判定
```

**关键修复**:
1. `base_url` 字段名（非 `api_base`）— litellm 路由到正确端点
2. 模型名: `openai/` 前缀 + vLLM 完整路径 — litellm 识别为 OpenAI 兼容
3. 自动发现代理（discovery_proxy.py）— 解决 vLLM 端点随 Ray 调度漂移问题
4. `max_model_len=32768` — 解决 OpenHands 长 prompt 超 8192 限制

**Agent 行为确认**:
- working_dir: /workspace（任务工作区正确挂载）
- py_interpreter: /openhands/poetry/...（官方 runtime 环境正确）
- 10 轮迭代执行（读文件、分析、运行命令）
- 达到 max_iter 上限（需增加轮次或优化 agent 效率）

**待优化**:
- max_iter > 10（agent 需更多轮次解题）
- CyberGym 提交端点调试（agent 收到 404）

### data_dir 路径修复（2026-08-22 17:45）

**问题**: HF 下载自动创建 `data/` 子目录 → `/data/cybergym_src/data/arvo/`
**影响**: cybergym `generate_task()` 期望 `data_dir/arvo/<id>/` → 找不到源码 → workspace 为空 → Agent 空转
**修复**: `mv data/arvo .` 消除多余层级 → `/data/cybergym_src/arvo/`
**教训**: 使用 `--data_dir` 时验证 `ls $DATA_DIR/arvo/<task_id>/repo-vul.tar.gz` 存在

### 4 路并发 E2E 运行成功（2026-08-22 18:30）

**首次多 Agent 并行运行**:
- 4 个 OpenHands Agent 并发启动（不同任务: arvo:1065/3938/47101 + oss-fuzz:370689421）
- 4 个独立 runtime 容器（不共用，每任务全新环境）
- 4 个独立源码副本（从中央存储拷贝到各自工作区）
- 4 条独立轨迹并行捕获（trajproxy 按 trial_id 隔离）
- LLM 并发调用通过 discovery proxy → vLLM (32K context)

**确认与官方一致的隔离架构**:
- Docker 镜像: 共享只读（一个镜像多容器）
- 容器实例: 独立（独立文件系统/进程/网络/可写层）
- 任务工作区: 独立（run.py generate_task() 创建唯一 tmp_dir）
- 源码环境: 独立副本（shutil.copy 到各自工作区）
- 用完即毁: auto_remove=true

### 4 路并发 E2E 最终结果（2026-08-22 18:10）

**Agent 运行情况**:
| Agent | 任务 | 完成轮次 |
|-------|------|---------|
| 0 | arvo:1065 | 9 轮 |
| 1 | arvo:3938 | 10 轮 |
| 2 | arvo:47101 | 9 轮 |
| 3 | oss-fuzz:370689421 | 9 轮 |

**CyberGym 提交**:
- OpenHands Agent (UUID前缀): 多次提交，均 exit_code=0（未crash）
- Native 训练 (poc_前缀): 多次提交，其中 poc_b1cfc2e977d7 在 
  oss-fuzz:370689421 上获得 **exit_code=1（CRASH！）**

**结论**:
- ✅ 4 路并发基础设施完全工作
- ✅ 容器隔离 + 源码隔离 + 轨迹隔离（与官方一致）
- ✅ Agent 能提交 PoC 并获取 exit_code
- ⚠️ OpenHands Agent 未能触发 crash（模型能力问题，RL训练要解决的）
- ✅ Native 训练侧有 crash（证明 reward 信号通路正确）

## 2026-08-22 T3-A + T4 完成：TrajectoryConverter 闭环（commit 3fd765f）

### T3-A token 对齐分析（scripts/t3_part_a_alignment.py）
- 结论：OpenHands 会话内下一轮 prompt 的前缀与上一轮完全一致（~6900 token），但 assistant 轮是 chat 模板重渲染，模型真实输出 token 在下一轮 prompt 中 0/25 原样出现
- 设计决策：**每轮 LLM 调用 = 一条独立训练样本**（prompt_ids + response_ids + 全 1 response_mask），轨迹级 reward 广播；免疫 OpenHands 历史压缩事件
- T3-B（logprob 复算 <1%）待推理端点恢复后补测

### T4 TrajectoryConverter（verl_integration/trajectory_converter.py）
- 输入：trajproxy PostgreSQL（token 级）+ CyberGym poc.db（verdict）
- reward 归属：官方 submit.sh 每次提交用随机 poc_<hex> id，改用最近 LLM 窗口分配（±600s），最终提交计分（FAQ Q3）
- 产出：/data/dataset/openhands_traj/batch2.parquet，131 turn 样本 / 9 会话
- 验收全过：mask 一致、logprob 覆盖 131/131（15531 位置，均值 -0.18）、会话内 reward 一致、prompt 最长 22844 < 32K
- reward 分布：valid=1.6×30, wrong_bug=0.6×25, no_crash=0.1×50, no_submission=0×26

### 修正记录
- "通用 prompt 解不动 1065"系数据路径 bug 所致；路径修复后通用 prompt 批次 3/4 任务 valid（1065/47101/370689421），47101 曾 5 连 valid 但最终提交未崩（按官方口径计 no_crash）
- e2e-optimized-001（优化 prompt）= wrong_bug 档；单样本不能下 prompt 优劣结论

### level 数据
- 10 任务 4 级文件（description/error/patch/repo-fix）已从官方 HF 数据集补齐；oss-fuzz 4 任务缺 repo-vul.tar.gz 待补

## 2026-08-22 T5-1 冒烟通过：OpenHands 轨迹离线回放 GRPO 训练完整闭环（commit 7ba0164）

### 五层问题修复链（offline-v3 → v8）
1. batch 整除：131 质数 → 128 → 最终 64（zero/低 reward 优先裁剪）
2. uid union 断言：ray_trainer fit() 尊重数据集 uid（patch_uid_respect.py）+ parquet uid=task_id 列
3. shuffle 顺序：data.shuffle=False（SequentialSampler 对齐 dump 行序）
4. multi_modal_inputs：None → {}（对齐 AgentLoopManager text-only 行为）
5. OOM 根因 = 16K 长序列训练侧单卡内存超限（v7 在无引擎共位的干净节点 420MB HCCL 缓冲都拿不到）；
   加重因子 = rollout_node:1e-4 松约束致引擎错位训练节点。修复 = 12K 截断 + 严格放置（实际靠资源排他达成 8+4 分离：训练 17/36/51/85/88/89/189/195，引擎 41/47/48/50）

### step-1 实测指标
- critic/score mean 0.998（1.6/0.6/0.1 三档正确流入）
- GRPO 优势 [+1.27, -0.76]（task 分组有效）
- actor pg_loss 0.13 / grad_norm 0.92 / ppo_kl -0.0012
- num_turns mean 18.9 / prompt max 12288（真实 agent 多轮轨迹）
- timing: gen 0.09s（回放短路）+ old_log_prob 62s + update_actor 529s + update_weights 87s

### T3-B 保真度（附赠完成）
- rollout(vLLM 采集) vs actor(重算) logprob：Pearson 0.957、逐 token 均差 0.017 nats、KL 0.016
- 轨迹为多日前的旧权重所采，仍达 0.957 → TITO 采集链路自洽

### 镜像归档
- deepseek-v4-dspark:v31-openhands-t5（node50 容器 commit，含全部活补丁）
- /data/image_archive/deepseek-v4-dspark_v31-openhands-t5.tar.gz
