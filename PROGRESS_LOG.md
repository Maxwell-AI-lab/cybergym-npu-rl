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
