#!/bin/bash
# Deploy multi-turn training files to all 12 cluster nodes.
# Usage (from repo root, local mac): bash deploy/deploy_multiturn.sh
#
# Files -> container cybergym-baseline-zhouzhi:
#   verl_integration/cybergym_tools_verl.py    (async tools + parser import)
#   verl_integration/deepseek_tool_parser.py   (native format parser)
#   verl_integration/cybergym_tools.py         (sync impl, import fallback)
#   verl_integration/tool_config.yaml
#   verl_integration/cybergym_reward.py
#   configs/train_cybergym_multiturn.sh        (head only)
#   train.parquet                              (head only, $1 optional path)

set -e
RELAY=root@119.8.234.170
CNAME=cybergym-baseline-zhouzhi
BASE=/data/z00666713/deepseek0715/cybergym_integration
HEAD=36
TRAIN_NODES="41 51 88 89 189 47 50"
ROLLOUT_NODES="17 195 85 48"
ALL_NODES="$HEAD $TRAIN_NODES $ROLLOUT_NODES"
STAGE=/data/z00666713/tmp/mt_deploy
PARQUET=${1:-/tmp/train.parquet}

echo "=== 1/3 stage files on relay ==="
ssh -o StrictHostKeyChecking=no $RELAY "rm -rf $STAGE && mkdir -p $STAGE/verl_integration $STAGE/configs"
for f in cybergym_tools_verl.py deepseek_tool_parser.py cybergym_tools.py tool_config.yaml cybergym_reward.py system_prompt.py; do
  scp -o StrictHostKeyChecking=no verl_integration/$f $RELAY:$STAGE/verl_integration/
done
scp -o StrictHostKeyChecking=no configs/train_cybergym_multiturn.sh $RELAY:$STAGE/configs/
scp -o StrictHostKeyChecking=no "$PARQUET" $RELAY:$STAGE/train.parquet

echo "=== 2/3 fan out to 12 nodes ==="
for ip in $ALL_NODES; do
  (
    ssh -o StrictHostKeyChecking=no $RELAY "
      set -e
      ssh -o StrictHostKeyChecking=no root@192.168.0.$ip \"mkdir -p $BASE/verl_integration $BASE/configs\"
      scp -q -o StrictHostKeyChecking=no $STAGE/verl_integration/*.py $STAGE/verl_integration/*.yaml root@192.168.0.$ip:$BASE/verl_integration/
      # head-only files
      if [ $ip -eq $HEAD ]; then
        scp -q -o StrictHostKeyChecking=no $STAGE/configs/train_cybergym_multiturn.sh root@192.168.0.$ip:$BASE/configs/
        scp -q -o StrictHostKeyChecking=no $STAGE/train.parquet root@192.168.0.$ip:/data/z00666713/tmp/train.parquet
      fi
      ssh -o StrictHostKeyChecking=no root@192.168.0.$ip \"
        docker exec $CNAME mkdir -p $BASE/verl_integration $BASE/configs
        for f in cybergym_tools_verl.py deepseek_tool_parser.py cybergym_tools.py tool_config.yaml cybergym_reward.py system_prompt.py; do
          docker cp $BASE/verl_integration/\\\$f $CNAME:$BASE/verl_integration/
        done
        if [ $ip -eq $HEAD ]; then
          docker cp $BASE/configs/train_cybergym_multiturn.sh $CNAME:$BASE/configs/
          docker exec $CNAME mkdir -p /data/dataset/cybergym
          docker cp /data/z00666713/tmp/train.parquet $CNAME:/data/dataset/cybergym/train.parquet
        fi
        docker exec $CNAME find $BASE -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
      \"
    " > /tmp/deploy_$ip.log 2>&1 && echo "node $ip: OK" || echo "node $ip: FAILED (see /tmp/deploy_$ip.log)"
  ) &
done
wait

echo "=== 3/3 verify ==="
for ip in $ALL_NODES; do
  CNT=$(ssh -o StrictHostKeyChecking=no $RELAY "ssh -o StrictHostKeyChecking=no root@192.168.0.$ip 'docker exec $CNAME grep -c CyberGymSubmitPocTool $BASE/verl_integration/cybergym_tools_verl.py 2>/dev/null'" 2>/dev/null)
  PARSER=$(ssh -o StrictHostKeyChecking=no $RELAY "ssh -o StrictHostKeyChecking=no root@192.168.0.$ip 'docker exec $CNAME grep -c register..deepseek $BASE/verl_integration/deepseek_tool_parser.py 2>/dev/null'" 2>/dev/null)
  echo "node $ip: tools_cls=$CNT parser=$PARSER (want 3/1)"
done
echo "deploy done"
