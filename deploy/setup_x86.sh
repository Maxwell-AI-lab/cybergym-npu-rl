#!/bin/bash
# ============================================================
# CyberGym x86 Server Deployment Script
# 基于 CyberGym v0.2.0 源码分析编写
#
# 运行环境: x86_64 Linux (Ubuntu/CentOS)
# 前置条件: Docker, Python 3.12+, 网络可达 Docker Hub
# ============================================================
set -euo pipefail

# --- 配置 (可通过环境变量覆盖) ---
CYBERGYM_PORT=${CYBERGYM_PORT:-8666}
CYBERGYM_DATA_DIR="${CYBERGYM_DATA_DIR:-${HOME}/cybergym_data}"
CYBERGYM_SERVER_DIR="${CYBERGYM_SERVER_DIR:-${HOME}/cybergym-server}"

# CyberGym Server 配置 (基于 src/cybergym/server/types.py ServerConfig)
export CYBERGYM_RATE_LIMIT_MAX_REQUESTS=${CYBERGYM_RATE_LIMIT_MAX_REQUESTS:-200}
export CYBERGYM_RATE_LIMIT_WINDOW_SECONDS=${CYBERGYM_RATE_LIMIT_WINDOW_SECONDS:-60}
export CYBERGYM_MAX_FILE_SIZE_MB=${CYBERGYM_MAX_FILE_SIZE_MB:-10}
export CYBERGYM_API_KEY=${CYBERGYM_API_KEY:-"cybergym-030a0cd7-5908-4862-8ab9-91f2bfc7b56d"}

# 10 个 subset 任务
TASKS=(
    "arvo:47101"
    "arvo:3938"
    "arvo:24993"
    "arvo:1065"
    "arvo:10400"
    "arvo:368"
    "oss-fuzz:42535201"
    "oss-fuzz:42535468"
    "oss-fuzz:370689421"
    "oss-fuzz:385167047"
)

echo "============================================================"
echo "  CyberGym x86 Server Deployment"
echo "  Port: ${CYBERGYM_PORT}"
echo "  Data: ${CYBERGYM_DATA_DIR}"
echo "  Server: ${CYBERGYM_SERVER_DIR}"
echo "  Rate Limit: ${CYBERGYM_RATE_LIMIT_MAX_REQUESTS} req / ${CYBERGYM_RATE_LIMIT_WINDOW_SECONDS}s"
echo "============================================================"

# ============================================================
# Phase 1: 系统依赖
# ============================================================
echo ""
echo "=== Phase 1: System Dependencies ==="

# Docker
if ! command -v docker &>/dev/null; then
    echo "[*] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER" 2>/dev/null || true
    echo "[✓] Docker installed"
fi
echo "[✓] Docker: $(docker --version)"

# Python 3.12+ (CyberGym pyproject.toml 要求 requires-python = ">=3.12")
if ! python3 -c "import sys; assert sys.version_info >= (3,12)" 2>/dev/null; then
    echo "[!] Python 3.12+ required (CyberGym pyproject.toml 要求)"
    echo "    Current: $(python3 --version 2>&1 || echo 'not found')"
    echo ""
    echo "    Install options:"
    echo "      Ubuntu: sudo apt install python3.12 python3.12-venv python3.12-dev"
    echo "      CentOS: sudo dnf install python3.12 python3.12-devel"
    echo "      Manual: https://www.python.org/downloads/"
    exit 1
fi
echo "[✓] Python: $(python3 --version)"

# ============================================================
# Phase 2: CyberGym 安装
# ============================================================
echo ""
echo "=== Phase 2: CyberGym Installation ==="

if [ ! -d "${CYBERGYM_SERVER_DIR}" ]; then
    echo "[*] Cloning CyberGym..."
    git clone https://github.com/sunblaze-ucb/cybergym.git "${CYBERGYM_SERVER_DIR}"
fi

cd "${CYBERGYM_SERVER_DIR}"

# 创建 venv
if [ ! -d ".venv" ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate

echo "[*] Installing CyberGym with server dependencies..."
pip install -e '.[server]' 2>&1 | tail -3

# 验证安装
python3 -c "from cybergym.server.server_utils import run_container; print('[✓] CyberGym server module loaded')"
python3 -c "from cybergym.task.types import verify_task; print('[✓] CyberGym task module loaded')"

# ============================================================
# Phase 3: 数据下载
# ============================================================
echo ""
echo "=== Phase 3: Download Benchmark Data ==="

mkdir -p "${CYBERGYM_DATA_DIR}"

# 检查 relay 上是否已有数据可以 scp
RELAY_HOST="119.8.234.170"
RELAY_DATA="/data/z00666713/cybergym_data"

if [ -d "${CYBERGYM_DATA_DIR}/data" ]; then
    echo "[✓] Data directory already exists: ${CYBERGYM_DATA_DIR}/data"
elif ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@${RELAY_HOST}" "test -d ${RELAY_DATA}/data" 2>/dev/null; then
    echo "[*] Found data on relay, copying via scp..."
    scp -r "root@${RELAY_HOST}:${RELAY_DATA}/data" "${CYBERGYM_DATA_DIR}/data"
    scp "root@${RELAY_HOST}:${RELAY_DATA}/tasks.json" "${CYBERGYM_DATA_DIR}/" 2>/dev/null || true
else
    echo "[*] Downloading from HuggingFace (subset only)..."
    pip install huggingface_hub 2>/dev/null

    # 使用 HF mirror (中国大陆)
    export HF_ENDPOINT=${HF_ENDPOINT:-"https://hf-mirror.com"}

    # 只下载 description.txt 和 source tarballs (不下载完整 240GB)
    for task_id in "${TASKS[@]}"; do
        subset="${task_id%%:*}"
        subid="${task_id#*:}"
        task_dir="${CYBERGYM_DATA_DIR}/data/${subset}/${subid}"

        if [ -f "${task_dir}/description.txt" ]; then
            echo "  [skip] ${task_id} already downloaded"
            continue
        fi

        mkdir -p "${task_dir}"
        echo "  [download] ${task_id}..."

        # Download description.txt
        curl -sL "${HF_ENDPOINT}/datasets/sunblaze-ucb/cybergym/resolve/main/data/${subset}/${subid}/description.txt" \
            -o "${task_dir}/description.txt" 2>/dev/null || echo "  [!] description.txt not found for ${task_id}"

        # Download repo-vul.tar.gz (source code for Agent to read)
        curl -sL "${HF_ENDPOINT}/datasets/sunblaze-ucb/cybergym/resolve/main/data/${subset}/${subid}/repo-vul.tar.gz" \
            -o "${task_dir}/repo-vul.tar.gz" 2>/dev/null || echo "  [!] repo-vul.tar.gz not found for ${task_id}"
    done

    # Download tasks.json
    curl -sL "${HF_ENDPOINT}/datasets/sunblaze-ucb/cybergym/resolve/main/tasks.json" \
        -o "${CYBERGYM_DATA_DIR}/tasks.json" 2>/dev/null || true
fi

# 验证数据
echo "[*] Verifying data files..."
data_ok=0
for task_id in "${TASKS[@]}"; do
    subset="${task_id%%:*}"
    subid="${task_id#*:}"
    desc="${CYBERGYM_DATA_DIR}/data/${subset}/${subid}/description.txt"
    if [ -f "$desc" ]; then
        data_ok=$((data_ok + 1))
    else
        echo "  [missing] ${task_id}: ${desc}"
    fi
done
echo "[✓] Data files: ${data_ok}/${#TASKS[@]} tasks have description.txt"

# ============================================================
# Phase 4: Docker 镜像
# ============================================================
echo ""
echo "=== Phase 4: Docker Images (20 images: 10 vul + 10 fix) ==="

# 优先从 relay docker save/load (同网段快)
# 如果失败则从 Docker Hub pull

pull_or_load_image() {
    local image=$1
    if docker image inspect "$image" &>/dev/null; then
        echo "  [skip] ${image} already exists"
        return 0
    fi

    # 尝试从 relay load
    local tar_name=$(echo "$image" | tr '/:' '_')
    if ssh -o ConnectTimeout=5 "root@${RELAY_HOST}" "docker save ${image} | gzip" 2>/dev/null | gunzip | docker load 2>/dev/null; then
        echo "  [loaded] ${image} from relay"
        return 0
    fi

    # 从 Docker Hub pull
    echo "  [pulling] ${image}..."
    if docker pull "$image" 2>/dev/null; then
        echo "  [pulled] ${image}"
        return 0
    fi

    echo "  [FAIL] ${image}"
    return 1
}

pulled=0
total=0
for task_id in "${TASKS[@]}"; do
    if [[ "$task_id" == arvo:* ]]; then
        subid="${task_id#arvo:}"
        for mode in vul fix; do
            total=$((total + 1))
            pull_or_load_image "n132/arvo:${subid}-${mode}" && pulled=$((pulled + 1))
        done
    elif [[ "$task_id" == oss-fuzz:* ]]; then
        subid="${task_id#oss-fuzz:}"
        for mode in vul fix; do
            total=$((total + 1))
            pull_or_load_image "cybergym/oss-fuzz:${subid}-${mode}" && pulled=$((pulled + 1))
        done
    fi
done
echo "[✓] Docker images: ${pulled}/${total}"

# ============================================================
# Phase 5: 启动 Server
# ============================================================
echo ""
echo "=== Phase 5: Start CyberGym Server ==="

LOG_DIR="${CYBERGYM_SERVER_DIR}/logs"
mkdir -p "${LOG_DIR}"

# 停掉旧 server
pkill -f "cybergym.server" 2>/dev/null || true
sleep 1

# 启动 server
# 关键配置通过环境变量 (types.py:9 ServerConfig, env_prefix="CYBERGYM_")
echo "[*] Starting CyberGym Server..."
echo "    Host: 0.0.0.0:${CYBERGYM_PORT}"
echo "    Rate limit: ${CYBERGYM_RATE_LIMIT_MAX_REQUESTS} req / ${CYBERGYM_RATE_LIMIT_WINDOW_SECONDS}s per agent"
echo "    API key: ${CYBERGYM_API_KEY}"
echo "    Log dir: ${LOG_DIR}"

nohup python3 -m cybergym.server \
    --host 0.0.0.0 \
    --port "${CYBERGYM_PORT}" \
    --log_dir "${LOG_DIR}" \
    > "${CYBERGYM_SERVER_DIR}/server.log" 2>&1 &

SERVER_PID=$!
echo $SERVER_PID > "${CYBERGYM_SERVER_DIR}/server.pid"

# 等待启动
echo "[*] Waiting for server to start..."
for i in $(seq 1 10); do
    sleep 1
    if curl -s "http://localhost:${CYBERGYM_PORT}/docs" >/dev/null 2>&1; then
        echo "[✓] Server running (PID: ${SERVER_PID})"
        break
    fi
    if [ $i -eq 10 ]; then
        echo "[!] Server not responding after 10s"
        echo "    Check log: tail -20 ${CYBERGYM_SERVER_DIR}/server.log"
        exit 1
    fi
done

# ============================================================
# Phase 6: 冒烟测试
# ============================================================
echo ""
echo "=== Phase 6: Smoke Test ==="

# 用 gen_task 生成一个测试任务，然后 submit 一个假 PoC
TEST_TASK="arvo:10400"
TEST_DIR="/tmp/cybergym_smoke_test"
rm -rf "${TEST_DIR}"

echo "[*] Generating test task for ${TEST_TASK}..."
source .venv/bin/activate
python3 -m cybergym.task.gen_task \
    --task-id "${TEST_TASK}" \
    --out-dir "${TEST_DIR}" \
    --data-dir "${CYBERGYM_DATA_DIR}/data" \
    --server "http://127.0.0.1:${CYBERGYM_PORT}" \
    --difficulty level1 2>&1 || {
    echo "[!] gen_task failed, trying direct submit test..."
}

# 直接 submit 一个假 PoC 测试 API
echo "[*] Testing submit-vul API..."
SMOKE_RESULT=$(python3 -c "
import hashlib, json, uuid, requests

task_id = '${TEST_TASK}'
agent_id = uuid.uuid4().hex
salt = 'CyberGym'
checksum = hashlib.sha256(f'{task_id}{agent_id}{salt}'.encode()).hexdigest()
metadata = json.dumps({'task_id': task_id, 'agent_id': agent_id, 'checksum': checksum, 'require_flag': False})

resp = requests.post(
    'http://127.0.0.1:${CYBERGYM_PORT}/submit-vul',
    data={'metadata': metadata},
    files={'file': ('poc.bin', b'\\x00' * 16)},
    timeout=30,
)
print(f'Status: {resp.status_code}')
if resp.status_code == 200:
    result = resp.json()
    print(f'exit_code: {result.get(\"exit_code\", \"N/A\")}')
    print(f'output: {result.get(\"output\", \"N/A\")[:200]}')
else:
    print(f'Error: {resp.text[:200]}')
" 2>&1)

echo "$SMOKE_RESULT"

if echo "$SMOKE_RESULT" | grep -q "exit_code"; then
    echo "[✓] Smoke test passed - API working"
else
    echo "[!] Smoke test failed - check server log"
fi

# ============================================================
# 完成
# ============================================================
echo ""
echo "============================================================"
echo "  Deployment Complete"
echo "============================================================"
echo ""
echo "  Server URL:  http://<this-host>:${CYBERGYM_PORT}"
echo "  Swagger UI:  http://<this-host>:${CYBERGYM_PORT}/docs"
echo "  Server PID:  ${SERVER_PID}"
echo "  Server Log:  tail -f ${CYBERGYM_SERVER_DIR}/server.log"
echo "  PoC DB:      ${LOG_DIR}/poc.db"
echo ""
echo "  Rate Limit:  ${CYBERGYM_RATE_LIMIT_MAX_REQUESTS} req / ${CYBERGYM_RATE_LIMIT_WINDOW_SECONDS}s"
echo "  API Key:     ${CYBERGYM_API_KEY}"
echo ""
echo "  从训练集群连接 (同网段直连):"
echo "    export CYBERGYM_SERVER_URL=http://<x86-ip>:${CYBERGYM_PORT}"
echo ""
echo "  停止 Server:"
echo "    kill ${SERVER_PID}"
echo ""
