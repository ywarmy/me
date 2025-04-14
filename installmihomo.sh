#!/bin/bash

# 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行此脚本 (使用 sudo)"
    exit 1
fi

# 获取 CPU 架构
echo "正在检测 CPU 架构..."
ARCH=$(uname -m)

case $ARCH in
    x86_64)
        MIHOMO_ARCH="amd64"
        ;;
    i686|i386)
        MIHOMO_ARCH="386"
        ;;
    aarch64|arm64)
        MIHOMO_ARCH="arm64"
        ;;
    armv7l)
        MIHOMO_ARCH="armv7"
        ;;
    *)
        echo "不支持的 CPU 架构: $ARCH"
        exit 1
esac

echo "检测到的 CPU 架构为: $ARCH，使用 mihomo 版本: $MIHOMO_ARCH"

# 获取最新版本的 mihomo 下载链接
MIHOMO_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep "tag_name" | cut -d'"' -f4)
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VERSION}.gz"

# 下载并解压 mihomo 二进制文件
echo "正在下载 mihomo ${MIHOMO_VERSION}..."
wget -q "$DOWNLOAD_URL" -O mihomo.gz
if [ $? -ne 0 ]; then
    echo "下载失败，请检查网络连接或 URL"
    exit 1
fi

gunzip mihomo.gz
mv mihomo /usr/local/bin/mihomo
chmod 755 /usr/local/bin/mihomo

# 创建配置目录并放入 config.yaml
echo "正在创建配置目录 /etc/mihomo ..."
mkdir -p /etc/mihomo
if [ -f ./config.yaml ]; then
    echo "将当前目录下的 config.yaml 放入 /etc/mihomo/"
    cp ./config.yaml /etc/mihomo/config.yaml
else
    echo "错误：当前目录下没有找到 config.yaml 文件"
    echo "请将你的 config.yaml 手动放入 /etc/mihomo/ 目录"
fi

# 创建 systemd 服务文件
echo "正在创建 systemd 服务文件..."
cat << EOF > /etc/systemd/system/mihomo.service
[Unit]
Description=mihomo Daemon, Another Clash Kernel.
After=network.target NetworkManager.service systemd-networkd.service iwd.service

[Service]
Type=simple
LimitNPROC=500
LimitNOFILE=1000000
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_TIME CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
Restart=always
ExecStartPre=/usr/bin/sleep 1s
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP \$MAINPID

[Install]
WantedBy=multi-user.target
EOF

# 重新加载 systemd 并启用服务
echo "重新加载 systemd 并启用 mihomo 服务..."
systemctl daemon-reload
systemctl enable mihomo
systemctl start mihomo

# 检查服务状态
echo "检查 mihomo 服务状态..."
systemctl status mihomo --no-pager

# 设置 IP 转发为持久化模式
echo "设置 IP 转发为持久化模式..."
sed -i '/net.ipv4.ip_forward/s/^#//;s/net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sed -i '/net.ipv6.conf.all.forwarding/s/^#//;s/net.ipv6.conf.all.forwarding=.*/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
sysctl -p

# 重启网络服务以应用更改（Debian 可能需要根据具体网络管理工具调整）
echo "重启网络服务..."
systemctl restart networking || echo "网络服务重启失败，可能需要手动检查网络配置"

echo "安装完成！"
echo "请访问 192.168.x.x:9090/ui 查看 mihomo Web 界面（确保 IP 和端口正确）"
echo "运行日志可通过以下命令查看：journalctl -u mihomo -o cat -f"
