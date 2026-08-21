#!/bin/bash
# 启动训练前的强制预检 —— 所有历史踩过的坑逐项排查
# 用法: 在 relay 上 bash preflight_check.sh
# 原则: NFS 写一次即全局一致；部署后必须逐节点验证；启动前必须全绿
set -u
RELAY=root@119.8.234.170
CNAME=cybergym-baseline-zhouzhi
B=/data/z00666713/deepseek0715/cybergym_integration
HEAD=36
ROLLOUT="17 195 85 48"
ALL="36 41 51 88 89 189 47 50 17 195 85 48"
X86=192.168.0.100
FAIL=0

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAIL=1; }

echo "===== 1. 文件内容标记（12 节点，防静默部署失败）====="
for ip in $ALL; do
  R=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@119.8.234.170 \
    "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 root@192.168.0.$ip \
     'docker exec $CNAME bash -c "
       y=\$(grep -c \"$X86:8666\" $B/verl_integration/tool_config.yaml 2>/dev/null)
       r=\$(grep -c \"$X86:8666\" $B/verl_integration/cybergym_reward.py 2>/dev/null)
       t=\$(grep -c \"_submit_semaphore\" $B/verl_integration/cybergym_tools_verl.py 2>/dev/null)
       p=\$(grep -c \"Task-aware routing\" $B/verl_integration/cybergym_tools_verl.py 2>/dev/null)
       d=\$(grep -c \"register\" $B/verl_integration/deepseek_tool_parser.py 2>/dev/null)
       echo \"\$y \$r \$t \$p \$d\""' 2>/dev/null)
  if [ "$R" = "1 1 3 1 5" ] || [ "$R" = "1 1 3 1 6" ]; then pass "node$ip"; else fail "node$ip got='$R' (want '1 1 3 1 ≥5')"; fi
done

echo "===== 2. 导入测试（防 r4 的 ModuleNotFoundError）====="
R=$(ssh -o StrictHostKeyChecking=no root@119.8.234.170 "ssh root@192.168.0.$HEAD 'docker exec $CNAME python3 -c \"
import sys; sys.path.insert(0, \\\"/data/z00666713/deepseek0715\\\")
from cybergym_integration.verl_integration.cybergym_tools_verl import CyberGymSubmitPocTool
print(\\\"IMPORT-OK\\\")\" 2>&1 | tail -1'" 2>/dev/null)
[ "$R" = "IMPORT-OK" ] && pass "head 节点导入" || fail "导入失败: $R"

echo "===== 3. 任务文件（rollout 节点，防 read_file 空转）====="
for ip in $ROLLOUT; do
  N=$(ssh -o StrictHostKeyChecking=no root@119.8.234.170 "ssh root@192.168.0.$ip 'docker exec $CNAME ls /tmp/cybergym_tasks/ 2>/dev/null | wc -l'" 2>/dev/null)
  [ "$N" = "10" ] && pass "node$ip tasks=10" || fail "node$ip tasks=$N (want 10)"
done

echo "===== 4. parquet（行数/Task ID/方言示例）====="
R=$(ssh -o StrictHostKeyChecking=no root@119.8.234.170 "ssh root@192.168.0.$HEAD 'docker exec $CNAME python3 -c \"
import pandas as pd
df = pd.read_parquet(\\\"/data/dataset/cybergym/train.parquet\\\")
u = df.iloc[0][\\\"prompt\\\"][1][\\\"content\\\"]
s = df.iloc[0][\\\"prompt\\\"][0][\\\"content\\\"]
ok = len(df)==10 and \\\"Task ID:\\\" in u and \\\"invoke_name\\\" in s
print(\\\"PQ-OK\\\" if ok else \\\"PQ-BAD\\\")\" 2>&1 | tail -1'" 2>/dev/null)
[ "$R" = "PQ-OK" ] && pass "parquet 10行+标记" || fail "parquet: $R"

echo "===== 5. x86 服务可达（rollout 节点直连，防 localhost 坑）====="
for ip in $ROLLOUT; do
  R=$(ssh -o StrictHostKeyChecking=no root@119.8.234.170 "ssh root@192.168.0.$ip 'docker exec $CNAME python3 -c \"
import urllib.request
urllib.request.urlopen(\\\"http://$X86:8666/docs\\\", timeout=5)
print(\\\"REACH-OK\\\")\" 2>&1 | tail -1'" 2>/dev/null)
  [ "$R" = "REACH-OK" ] && pass "node$ip → x86" || fail "node$ip 不可达: $R"
done

echo "===== 6. 训练脚本关键配置（防 hydra 路径坑）====="
R=$(ssh -o StrictHostKeyChecking=no root@119.8.234.170 "ssh root@192.168.0.$HEAD 'docker exec $CNAME grep -c \"rollout.agent.default_agent_loop=\" $B/configs/train_cybergym_multiturn.sh'" 2>/dev/null)
[ "$R" = "1" ] && pass "agent loop 路径正确" || fail "agent 配置行异常 ($R)"

echo "===== 7. 集群空闲 ====="
N=$(ssh -o StrictHostKeyChecking=no root@119.8.234.170 "ssh root@192.168.0.$HEAD 'docker exec $CNAME pgrep -cf main_ppo'" 2>/dev/null)
[ "${N:-0}" = "0" ] && pass "无残留训练进程" || fail "有 main_ppo 在跑 (先停或等完)"

echo
if [ $FAIL -eq 0 ]; then echo "🎉 ALL GREEN — 可以启动训练"; else echo "⛔ 存在红灯 — 修复后再启动"; fi
exit $FAIL
