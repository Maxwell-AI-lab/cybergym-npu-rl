#!/bin/bash
# ============================================================
# CyberGym x86 Server Deployment Script
# Run on the x86 server (32C/64GB/500GB+)
# ============================================================
set -euo pipefail

CYBERGYM_PORT=${CYBERGYM_PORT:-8666}
CYBERGYM_DATA_DIR="${HOME}/cybergym_data"
CYBERGYM_SERVER_DIR="${HOME}/cybergym-server"
POC_SAVE_DIR="${CYBERGYM_SERVER_DIR}/poc_store"

echo "=== Phase 1: System Dependencies ==="

# Docker
if ! command -v docker &>/dev/null; then
    echo "[*] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"
    echo "[!] Please re-login or run 'newgrp docker' to apply group"
fi

# Python 3.11+
if ! python3 -c "import sys; assert sys.version_info >= (3,11)" 2>/dev/null; then
    echo "[*] Python 3.11+ required. Current:"
    python3 --version
    echo "[!] Please install Python 3.11+"
    exit 1
fi

echo "=== Phase 2: CyberGym Installation ==="

if [ ! -d "${CYBERGYM_SERVER_DIR}" ]; then
    echo "[*] Cloning CyberGym..."
    git clone https://github.com/sunblaze-ucb/cybergym.git "${CYBERGYM_SERVER_DIR}"
fi

cd "${CYBERGYM_SERVER_DIR}"

# Install in venv
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate

pip install -e '.[server]' 2>/dev/null || pip install -e .

echo "=== Phase 3: Download Benchmark Data ==="

# HuggingFace data (~240GB full, but we only need subset)
if [ ! -d "${CYBERGYM_DATA_DIR}" ]; then
    echo "[*] Downloading CyberGym benchmark data (subset)..."
    pip install huggingface_hub
    # Use HF mirror if in China
    export HF_ENDPOINT=${HF_ENDPOINT:-"https://hf-mirror.com"}
    huggingface-cli download sunblaze-ucb/cybergym \
        --repo-type dataset \
        --local-dir "${CYBERGYM_DATA_DIR}"
fi

echo "=== Phase 4: Download Docker Images (Subset 10 Tasks) ==="

# The subset download script handles pulling the right Docker images
echo "[*] Downloading subset Docker images..."
python scripts/server_data/download_subset.py 2>/dev/null || {
    echo "[!] Subset download script not found, pulling images manually..."
    
    # Read task IDs from our task list
    TASK_LIST="$(dirname "$0")/../data/task_list.json"
    if [ -f "$TASK_LIST" ]; then
        TASKS=$(python3 -c "import json; [print(t) for t in json.load(open('$TASK_LIST'))]")
    else
        # Default subset tasks from CyberGym README
        TASKS="arvo:47101
arvo:3938
arvo:24993
arvo:1065
arvo:10400
arvo:368
oss-fuzz:42535201
oss-fuzz:42535468
oss-fuzz:370689421
oss-fuzz:385167047"
    fi
    
    for task_id in $TASKS; do
        if [[ "$task_id" == arvo:* ]]; then
            arvo_id="${task_id#arvo:}"
            echo "[*] Pulling n132/arvo:${arvo_id}-vul ..."
            docker pull "n132/arvo:${arvo_id}-vul" || echo "[!] Failed: n132/arvo:${arvo_id}-vul"
            docker pull "n132/arvo:${arvo_id}-fix" || echo "[!] Failed: n132/arvo:${arvo_id}-fix"
        elif [[ "$task_id" == oss-fuzz:* ]]; then
            fuzz_id="${task_id#oss-fuzz:}"
            echo "[*] Pulling cybergym/oss-fuzz:${fuzz_id}-vul ..."
            docker pull "cybergym/oss-fuzz:${fuzz_id}-vul" || echo "[!] Failed: cybergym/oss-fuzz:${fuzz_id}-vul"
            docker pull "cybergym/oss-fuzz:${fuzz_id}-fix" || echo "[!] Failed: cybergym/oss-fuzz:${fuzz_id}-fix"
        fi
    done
}

echo "=== Phase 5: Start CyberGym Server ==="

mkdir -p "${POC_SAVE_DIR}"

# Kill existing server if running
pkill -f "cybergym.server" 2>/dev/null || true

# Start server (bind to 0.0.0.0 since we'll use SSH tunnel)
echo "[*] Starting CyberGym Server on port ${CYBERGYM_PORT}..."
nohup python3 -m cybergym.server \
    --host 0.0.0.0 \
    --port "${CYBERGYM_PORT}" \
    --log_dir "${POC_SAVE_DIR}" \
    --db_path "${POC_SAVE_DIR}/poc.db" \
    > "${CYBERGYM_SERVER_DIR}/server.log" 2>&1 &

echo $! > "${CYBERGYM_SERVER_DIR}/server.pid"

sleep 3

# Verify
if curl -s "http://localhost:${CYBERGYM_PORT}/docs" >/dev/null 2>&1; then
    echo "[✓] CyberGym Server running on port ${CYBERGYM_PORT}"
else
    echo "[!] Server may not be ready yet. Check: tail -f ${CYBERGYM_SERVER_DIR}/server.log"
fi

echo "=== Phase 6: Test Submission ==="

# Generate a test task and try a fake PoC submission
echo "[*] Running smoke test..."
python3 -m cybergym.task.gen_task \
    --task-id "arvo:10400" \
    --out-dir /tmp/cybergym_test \
    --data-dir "${CYBERGYM_DATA_DIR}/data" \
    --server "http://127.0.0.1:${CYBERGYM_PORT}" \
    --difficulty level1 2>/dev/null && {
    echo -en "\x00\x01\x02\x03" > /tmp/cybergym_test/poc
    bash /tmp/cybergym_test/submit.sh /tmp/cybergym_test/poc
    echo ""
    echo "[✓] Smoke test passed!"
} || echo "[!] Smoke test skipped or failed (non-critical)"

echo ""
echo "=== Deployment Complete ==="
echo "Server: http://0.0.0.0:${CYBERGYM_PORT}"
echo "Log:    tail -f ${CYBERGYM_SERVER_DIR}/server.log"
echo "PID:    $(cat ${CYBERGYM_SERVER_DIR}/server.pid 2>/dev/null || echo 'unknown')"
echo ""
echo "Next: Set up SSH tunnel from training cluster to this server"
echo "  bash $(dirname "$0")/setup_tunnel.sh"
