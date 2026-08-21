#!/bin/bash
# CyberGym training launcher script

set -e

cd /data/z00666713/deepseek0715/cybergym_integration

# Set environment variables
export CYBERGYM_SERVER_URL="http://192.168.0.100:8666"
export PYTHONPATH="/data/z00666713/deepseek0715:${PYTHONPATH}"

# Launch verl training
python3 -m verl.trainer.main_ppo \
    config=configs/train_cybergym.sh \
    --config-name=verl_training \
    "$@"
