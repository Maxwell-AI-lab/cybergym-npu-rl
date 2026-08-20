#!/bin/bash
# ============================================================
# CyberGym 网络连通性验证
#
# x86 服务器和 NPU 训练集群在同一网段内，无需 SSH 隧道。
# 此脚本仅验证网络连通性。
# ============================================================
set -euo pipefail

X86_HOST="${X86_HOST:-YOUR_X86_SERVER_IP}"
CYBERGYM_PORT="${CYBERGYM_PORT:-8666}"
SERVER_URL="http://${X86_HOST}:${CYBERGYM_PORT}"

echo "=== CyberGym Network Verification ==="
echo "Server: ${SERVER_URL}"
echo ""

# 1. Ping 测试
echo "[*] Ping test..."
if ping -c 2 -W 2 "${X86_HOST}" &>/dev/null; then
    echo "[✓] ${X86_HOST} reachable (ping)"
else
    echo "[!] ${X86_HOST} not reachable (ping may be disabled)"
fi

# 2. HTTP 连通测试
echo "[*] HTTP connectivity test..."
if curl -s --connect-timeout 5 "${SERVER_URL}/docs" >/dev/null 2>&1; then
    echo "[✓] CyberGym Server reachable at ${SERVER_URL}"
else
    echo "[✗] Server not reachable"
    echo ""
    echo "Possible causes:"
    echo "  1. Server not started: ssh ${X86_HOST} and run setup_x86.sh"
    echo "  2. Firewall blocking port ${CYBERGYM_PORT}"
    echo "     Fix: sudo ufw allow ${CYBERGYM_PORT}  (Ubuntu)"
    echo "     Fix: sudo firewall-cmd --add-port=${CYBERGYM_PORT}/tcp  (CentOS)"
    exit 1
fi

# 3. API 功能测试
echo "[*] API smoke test..."
RESP=$(curl -s --connect-timeout 5 "${SERVER_URL}/openapi.json" 2>/dev/null)
if echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert '/submit-vul' in d['paths']" 2>/dev/null; then
    echo "[✓] /submit-vul endpoint available"
else
    echo "[!] API endpoints not found"
fi

# 4. 输出配置
echo ""
echo "=== Configuration for Training ==="
echo ""
echo "Add to train_cybergym.sh:"
echo "  export CYBERGYM_SERVER_URL=\"${SERVER_URL}\""
echo ""
echo "Add to reward function env:"
echo "  export CYBERGYM_SERVER_URL=\"${SERVER_URL}\""
echo "  export CYBERGYM_API_KEY=\"cybergym-030a0cd7-5908-4862-8ab9-91f2bfc7b56d\""
echo ""
