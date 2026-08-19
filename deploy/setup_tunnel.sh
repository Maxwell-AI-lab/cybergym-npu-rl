#!/bin/bash
# ============================================================
# SSH Tunnel: Training Cluster → x86 CyberGym Server
# Run on the head node (192.168.0.36) or relay
# ============================================================
set -euo pipefail

# --- Configuration ---
# x86 server hostname/IP (change to your actual server)
X86_HOST="${X86_HOST:-YOUR_X86_SERVER_IP}"
X86_USER="${X86_USER:-root}"
X86_SSH_PORT="${X86_SSH_PORT:-22}"

# CyberGym server port on x86
CYBERGYM_PORT="${CYBERGYM_PORT:-8666}"

# Local bind address (on training cluster side)
LOCAL_BIND_HOST="0.0.0.0"
LOCAL_BIND_PORT="${CYBERGYM_PORT}"

echo "=== CyberGym SSH Tunnel Setup ==="
echo "Remote: ${X86_HOST}:${CYBERGYM_PORT}"
echo "Local:  ${LOCAL_BIND_HOST}:${LOCAL_BIND_PORT}"
echo ""

# Kill existing tunnel
echo "[*] Cleaning up existing tunnel..."
pkill -f "ssh.*-L.*${LOCAL_BIND_PORT}:${X86_HOST}:${CYBERGYM_PORT}" 2>/dev/null || true
sleep 1

# Create persistent tunnel
echo "[*] Creating SSH tunnel..."
nohup ssh -N \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=4 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -p "${X86_SSH_PORT}" \
    -L "${LOCAL_BIND_HOST}:${LOCAL_BIND_PORT}:${X86_HOST}:${CYBERGYM_PORT}" \
    "${X86_USER}@${X86_HOST}" \
    > /tmp/cybergym_tunnel.log 2>&1 &

TUNNEL_PID=$!
echo $TUNNEL_PID > /tmp/cybergym_tunnel.pid
sleep 3

# Verify tunnel
if kill -0 $TUNNEL_PID 2>/dev/null; then
    echo "[✓] SSH tunnel active (PID: ${TUNNEL_PID})"
    echo "    Test: curl http://localhost:${LOCAL_BIND_PORT}/docs"
    
    # Quick connectivity test
    if curl -s --connect-timeout 5 "http://localhost:${LOCAL_BIND_PORT}/docs" >/dev/null 2>&1; then
        echo "[✓] CyberGym Server reachable through tunnel"
    else
        echo "[!] Tunnel active but server not reachable yet"
    fi
else
    echo "[!] Tunnel failed. Check: cat /tmp/cybergym_tunnel.log"
    exit 1
fi

echo ""
echo "=== Tunnel Config ==="
echo "CyberGym URL (from training cluster): http://localhost:${LOCAL_BIND_PORT}"
echo "Tunnel PID: ${TUNNEL_PID}"
echo "Tunnel log: /tmp/cybergym_tunnel.log"
echo ""
echo "To kill: kill \$(cat /tmp/cybergym_tunnel.pid)"
