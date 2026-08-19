#!/bin/bash
# Pull Docker images for CyberGym subset tasks (10 tasks)
# Run on relay server: 119.8.234.170

set -e

LOG_FILE="/data/z00666713/cybergym_data/docker_pull.log"

echo "=== CyberGym Docker Image Pull ===" | tee "$LOG_FILE"
echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# arvo tasks (6)
ARVO_IDS=(47101 3938 24993 1065 10400 368)

# oss-fuzz tasks (4)
OSSFUZZ_IDS=(42535201 42535468 370689421 385167047)

TOTAL=0
SUCCESS=0

for id in "${ARVO_IDS[@]}"; do
    TOTAL=$((TOTAL+1))
    IMG="n132/arvo:${id}-vul"
    echo "[$TOTAL] Pulling $IMG ..." | tee -a "$LOG_FILE"
    if docker pull "$IMG" 2>&1 | tail -1 | tee -a "$LOG_FILE"; then
        SUCCESS=$((SUCCESS+1))
    else
        echo "  [FAIL] $IMG" | tee -a "$LOG_FILE"
    fi
done

for id in "${OSSFUZZ_IDS[@]}"; do
    TOTAL=$((TOTAL+1))
    IMG="cybergym/oss-fuzz:${id}-vul"
    echo "[$TOTAL] Pulling $IMG ..." | tee -a "$LOG_FILE"
    if docker pull "$IMG" 2>&1 | tail -1 | tee -a "$LOG_FILE"; then
        SUCCESS=$((SUCCESS+1))
    else
        echo "  [FAIL] $IMG" | tee -a "$LOG_FILE"
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "=== Pull Complete ===" | tee -a "$LOG_FILE"
echo "Finished: $(date)" | tee -a "$LOG_FILE"
echo "Success: $SUCCESS / $TOTAL" | tee -a "$LOG_FILE"
