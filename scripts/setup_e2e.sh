#!/bin/bash
# E2E 评测环境一键搭建（在 x86 上执行）
# 前置: 数据集已下载到 /data/cybergym-e2e/data/

set -e
echo "=== [1/5] 安装 Python 依赖 ==="
/data/e2e_venv/bin/pip install -q tomli tomli_w httpx docker

echo "=== [2/5] 系统配置 ==="
sudo sysctl -w vm.mmap_rnd_bits=28 2>/dev/null || echo "  (需要 root 权限设置 ASLR)"
sudo apt-get install -y -qq sudo git >/dev/null 2>&1

echo "=== [3/5] 数据完整性校验 ==="
/data/e2e_venv/bin/python /tmp/verify_e2e.py
if [ $? -ne 0 ]; then
    echo "❌ 校验失败，请检查缺失文件"
    exit 1
fi

echo "=== [4/5] Docker 镜像检查 ==="
REQUIRED=$(wc -l < /tmp/e2e_images.txt)
AVAILABLE=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -cE "n132/arvo.*-fix|base-builder" || echo 0)
echo "  需要: $REQUIRED | 可用: $AVAILABLE"

echo "=== [5/5] 环境就绪 ==="
echo ""
echo "  数据集: $(find /data/cybergym-e2e/data -name src.tgz | wc -l)/920 任务"
echo "  镜像:   $AVAILABLE 个"
echo "  Python: /data/e2e_venv/bin/python"
echo ""
echo "  下一步: 配置 LLM 端点后运行单任务测试"
echo "    export OPENAI_BASE_URL=http://<vLLM地址>:8000/v1"
echo "    export OPENAI_API_KEY=EMPTY"
echo "    cd /data/cybergym-e2e && python3 scripts/run_agent.py wasm3/arvo_33318 --mode e2e"
