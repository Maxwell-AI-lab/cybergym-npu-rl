#!/bin/bash
# Download only the essential files for subset 10 tasks
# Run on relay: 119.8.234.170

set -e

DATA_DIR="/data/z00666713/cybergym_data"
BASE_URL="https://huggingface.co/datasets/sunblaze-ucb/cybergym/resolve/main"
LOG_FILE="${DATA_DIR}/subset_download.log"

echo "=== CyberGym Subset Download ===" | tee "$LOG_FILE"
echo "Started: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Task IDs
ARVO_IDS=(47101 3938 24993 1065 10400 368)
OSSFUZZ_IDS=(42535201 42535468 370689421 385167047)

# Download tasks.json
echo "[1] Downloading tasks.json..." | tee -a "$LOG_FILE"
mkdir -p "${DATA_DIR}"
curl -sL "${BASE_URL}/tasks.json" -o "${DATA_DIR}/tasks.json"
echo "  [✓] Saved tasks.json ($(stat -f%z "${DATA_DIR}/tasks.json" 2>/dev/null || stat -c%s "${DATA_DIR}/tasks.json" 2>/dev/null) bytes)" | tee -a "$LOG_FILE"

# Download description.txt for each task
echo "" | tee -a "$LOG_FILE"
echo "[2] Downloading task descriptions..." | tee -a "$LOG_FILE"

for id in "${ARVO_IDS[@]}"; do
    echo "  arvo:${id}..." | tee -a "$LOG_FILE"
    mkdir -p "${DATA_DIR}/data/arvo/${id}"
    curl -sL "${BASE_URL}/data/arvo/${id}/description.txt" -o "${DATA_DIR}/data/arvo/${id}/description.txt"
    if [ -s "${DATA_DIR}/data/arvo/${id}/description.txt" ]; then
        echo "    [✓] $(wc -c < "${DATA_DIR}/data/arvo/${id}/description.txt") bytes" | tee -a "$LOG_FILE"
    else
        echo "    [✗] Failed or empty" | tee -a "$LOG_FILE"
    fi
done

for id in "${OSSFUZZ_IDS[@]}"; do
    echo "  oss-fuzz:${id}..." | tee -a "$LOG_FILE"
    mkdir -p "${DATA_DIR}/data/oss-fuzz/${id}"
    curl -sL "${BASE_URL}/data/oss-fuzz/${id}/description.txt" -o "${DATA_DIR}/data/oss-fuzz/${id}/description.txt"
    if [ -s "${DATA_DIR}/data/oss-fuzz/${id}/description.txt" ]; then
        echo "    [✓] $(wc -c < "${DATA_DIR}/data/oss-fuzz/${id}/description.txt") bytes" | tee -a "$LOG_FILE"
    else
        echo "    [✗] Failed or empty" | tee -a "$LOG_FILE"
    fi
done

echo "" | tee -a "$LOG_FILE"
echo "=== Download Complete ===" | tee -a "$LOG_FILE"
echo "Finished: $(date)" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Total size:" | tee -a "$LOG_FILE"
du -sh "${DATA_DIR}" | tee -a "$LOG_FILE"
