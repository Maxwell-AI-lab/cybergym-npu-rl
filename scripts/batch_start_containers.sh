#!/bin/bash
# 批量在推理节点启动容器
# 节点列表: 17, 195, 85, 48

PASSWORD="${NODE_PASSWORD:?set NODE_PASSWORD env var}"
NODES=(17 195 85 48)

for node in "${NODES[@]}"; do
    IP="192.168.0.$node"
    echo "=== Starting container on $IP ==="
    
    # 使用 expect 来处理密码
    expect << EOF
set timeout 30
spawn ssh -o StrictHostKeyChecking=no root@$IP
expect {
    "password:" {
        send "$PASSWORD\r"
    }
    timeout {
        puts "Timeout connecting to $IP"
        exit 1
    }
}

expect "# "

# 检查是否有 v30-fixed 镜像
send "docker images | grep v30-fixed\r"
expect "# "

# 检查是否已有容器运行
send "docker ps | grep cybergym || echo 'no cybergym container'\r"
expect "# "

# 启动容器
send "docker run -d --name cybergym-baseline-zhouzhi \
  --ipc=host --net=host --privileged \
  --device=/dev/davinci0 --device=/dev/davinci1 --device=/dev/davinci2 --device=/dev/davinci3 \
  --device=/dev/davinci4 --device=/dev/davinci5 --device=/dev/davinci6 --device=/dev/davinci7 \
  --device=/dev/davinci_manager --device=/dev/devmm_svm --device=/dev/hisi_hdc \
  -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
  -v /usr/local/Ascend/add-ons:/usr/local/Ascend/add-ons \
  -v /usr/local/sbin/npu-smi:/usr/local/sbin/npu-smi \
  -v /usr/local/sbin:/usr/local/sbin \
  -v /etc/ascend_install.info:/etc/ascend_install.info \
  -v /data_nv1/models:/data_nv1/models \
  -v /data:/data \
  --entrypoint '' \
  deepseek-v4-dspark:v30-fixed /usr/local/python3.12.13/bin/python3 -c 'import time; time.sleep(86400*30)'\r"

expect "# "
send "docker ps | grep cybergym\r"
expect "# "
send "exit\r"
expect eof
EOF
    
    echo ""
done
