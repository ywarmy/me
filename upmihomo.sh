#!/bin/sh

# 检查是否为 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "请以 root 权限运行此脚本 (使用 sudo)"
    exit 1
fi

# 检测 CPU 架构
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
        ;;
esac

echo "检测到的 CPU 架构为: $ARCH，使用 mihomo 版本: $MIHOMO_ARCH"

# 获取 mihomo 最新版本号
MIHOMO_VERSION=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases/latest | grep "tag_name" | cut -d'"' -f4)
DOWNLOAD_URL="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/mihomo-linux-${MIHOMO_ARCH}-${MIHOMO_VERSION}.gz"

# 下载并安装 mihomo
echo "正在下载 mihomo ${MIHOMO_VERSION}..."
wget -q "$DOWNLOAD_URL" -O /tmp/mihomo.gz
if [ $? -ne 0 ]; then
    echo "下载失败，请检查网络连接或 URL"
    exit 1
fi

gunzip -f /tmp/mihomo.gz
mv /tmp/mihomo /usr/bin/mihomo
chmod 0755 /usr/bin/mihomo

echo "mihomo 安装完成，路径：/usr/bin/mihomo，权限：0755"

