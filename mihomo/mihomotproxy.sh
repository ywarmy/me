#!/bin/bash
set -Eeuo pipefail
set -o pipefail

###############################################################################
# Mihomo Pure TProxy Gateway
#
# 功能：
#   1. LAN 客户端 TCP/UDP 透明代理
#   2. 本机 TCP/UDP 透明代理
#   3. 不使用 TUN
#   4. 不使用 HTTP_PROXY / HTTPS_PROXY
#   5. Mihomo DNS 监听 53
#   6. 使用 Mihomo Fake-IP
#   7. 不进行 DNS 劫持
#
# 网络：
#   LAN       192.168.11.0/24
#   Mixed     7890
#   TProxy    7893
#   DNS       53
#   API       9090
#
# TProxy：
#   MARK      0x1
#   ROUTE     100
#
###############################################################################


###############################################################################
# 参数
###############################################################################

MIHOMO_BIN="/usr/local/bin/mihomo"

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"

NFT_DIR="/etc/nftables.d"
NFT_FILE="${NFT_DIR}/mihomo-tproxy.nft"

POLICY_SCRIPT="/usr/local/sbin/mihomo-policy.sh"

POLICY_SERVICE="/etc/systemd/system/mihomo-policy.service"
MIHOMO_SERVICE="/etc/systemd/system/mihomo.service"

SYSCTL_FILE="/etc/sysctl.d/99-mihomo-tproxy.conf"

BACKUP_DIR="/root/mihomo-backups"

LAN_CIDR="192.168.11.0/24"

MIXED_PORT="7890"
TPROXY_PORT="7893"
DNS_PORT="53"
API_PORT="9090"

MARK="0x1"
TABLE="100"

MIHOMO_USER="mihomo"
MIHOMO_GROUP="mihomo"

ACTION="${1:-install}"


###############################################################################
# 输出
###############################################################################

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

ok() {
    echo "[OK] $1"
}

warn() {
    echo "[WARNING] $1"
}

die() {
    echo
    echo "[ERROR] $1"
    exit 1
}


###############################################################################
# 错误处理
###############################################################################

trap '
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "============================================================"
        echo "[ERROR] 脚本执行失败"
        echo "退出码：$rc"
        echo "行号：${LINENO}"
        echo "============================================================"
    fi
    exit "$rc"
' ERR


###############################################################################
# Root
###############################################################################

check_root() {

    [ "$EUID" -eq 0 ] ||
        die "请使用 root 运行"

}


###############################################################################
# 架构
###############################################################################

detect_arch() {

    case "$(uname -m)" in

        x86_64)
            ARCH="amd64"
            ;;

        aarch64|arm64)
            ARCH="arm64"
            ;;

        armv7l)
            ARCH="armv7"
            ;;

        *)
            die "不支持的 CPU 架构：$(uname -m)"
            ;;

    esac

    ok "架构：$(uname -m) → ${ARCH}"

}


###############################################################################
# 系统检查
###############################################################################

check_system() {

    log "检查系统"

    command -v apt >/dev/null 2>&1 ||
        die "没有 apt"

    command -v systemctl >/dev/null 2>&1 ||
        die "没有 systemctl"

    command -v nft >/dev/null 2>&1 ||
        warn "当前没有 nft，稍后安装"

    ok "系统基础环境正常"

}


###############################################################################
# 依赖
###############################################################################

install_dependencies() {

    log "安装依赖"

    export DEBIAN_FRONTEND=noninteractive

    apt update

    apt install -y \
        curl \
        wget \
        jq \
        nftables \
        iproute2 \
        ca-certificates \
        gzip

    ok "依赖安装完成"

}


###############################################################################
# 目录
###############################################################################

###############################################################################
# 创建 Mihomo 目录
###############################################################################

create_directories() {

    log "创建 Mihomo 目录"

    mkdir -p "$MIHOMO_DIR"
    mkdir -p "$MIHOMO_DIR/ui"
    mkdir -p "$NFT_DIR"
    mkdir -p "$BACKUP_DIR"

    ok "目录创建完成"
}


###############################################################################
# 创建专用 Mihomo 用户
###############################################################################

create_mihomo_user() {

    log "创建 Mihomo 专用用户"

    #
    # 创建专用组
    #
    if getent group "$MIHOMO_GROUP" >/dev/null 2>&1; then

        ok "用户组 $MIHOMO_GROUP 已存在"

    else

        groupadd --system "$MIHOMO_GROUP"

        ok "已创建用户组 $MIHOMO_GROUP"

    fi


    #
    # 创建专用用户
    #
    if id "$MIHOMO_USER" >/dev/null 2>&1; then

        ok "用户 $MIHOMO_USER 已存在"

    else

        useradd \
            --system \
            --gid "$MIHOMO_GROUP" \
            --no-create-home \
            --shell /usr/sbin/nologin \
            "$MIHOMO_USER"

        ok "已创建用户 $MIHOMO_USER"

    fi


    #
    # Mihomo 需要读取配置、规则、GeoData、UI 等文件。
    #
    chown -R "$MIHOMO_USER:$MIHOMO_GROUP" "$MIHOMO_DIR"

    chmod 755 "$MIHOMO_DIR"
    chmod 755 "$MIHOMO_DIR/ui"

    ok "Mihomo 目录权限设置完成"
}


###############################################################################
# Mihomo
###############################################################################

get_latest_version() {

    curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        https://api.github.com/repos/MetaCubeX/mihomo/releases/latest |
        jq -er '.tag_name'

}


get_current_version() {

    [ -x "$MIHOMO_BIN" ] || return 0

    "$MIHOMO_BIN" -v 2>/dev/null |
        grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1 ||
        true

}


install_mihomo() {

    log "安装 / 更新 Mihomo"

    local current=""
    local latest=""
    local url=""

    current="$(get_current_version)"
    latest="$(get_latest_version)"

    echo "当前版本：${current:-未安装}"
    echo "最新版本：$latest"

    if [ "$current" = "$latest" ]; then

        ok "Mihomo 已经是最新版"

        return

    fi

    url="https://github.com/MetaCubeX/mihomo/releases/download/${latest}/mihomo-linux-${ARCH}-${latest}.gz"

    echo
    echo "下载："
    echo "$url"

    rm -f /tmp/mihomo.gz
    rm -f /tmp/mihomo

    wget \
        --timeout=30 \
        --tries=3 \
        -O /tmp/mihomo.gz \
        "$url"

    gzip -df /tmp/mihomo.gz

    [ -f /tmp/mihomo ] ||
        die "Mihomo 解压失败"

    chmod 755 /tmp/mihomo

    /tmp/mihomo -v >/dev/null 2>&1 ||
        die "Mihomo 无法运行"

    install -m 755 /tmp/mihomo "$MIHOMO_BIN"

    rm -f /tmp/mihomo

    ok "Mihomo 安装完成"

    "$MIHOMO_BIN" -v || true

}


###############################################################################
# 配置
###############################################################################

install_config() {

    log "安装 config.yaml"

    [ -f "./config.yaml" ] ||
        die "当前目录没有 config.yaml"

    if [ -f "$MIHOMO_CONFIG" ]; then

        local backup

        backup="${BACKUP_DIR}/config.yaml.$(date +%Y%m%d-%H%M%S)"

        cp -a "$MIHOMO_CONFIG" "$backup"

        ok "旧配置已备份：$backup"

    fi

    cp -f "./config.yaml" "$MIHOMO_CONFIG"

    chown "$MIHOMO_USER:$MIHOMO_GROUP" "$MIHOMO_CONFIG" 2>/dev/null || true

    chmod 600 "$MIHOMO_CONFIG"

    ok "config.yaml 安装完成"

}


###############################################################################
# 配置检查
###############################################################################

check_config() {

    log "检查 Mihomo 配置"

    "$MIHOMO_BIN" \
        -t \
        -d "$MIHOMO_DIR"

    ok "Mihomo 配置检查通过"

}


###############################################################################
# 检查关键配置
###############################################################################

check_required_config() {

    log "检查关键配置"

    grep -Eq \
        '^[[:space:]]*tproxy-port:[[:space:]]*7893[[:space:]]*$' \
        "$MIHOMO_CONFIG" ||
        die "config.yaml 必须设置：tproxy-port: 7893"

    ok "tproxy-port = 7893"


    grep -Eq \
        '^[[:space:]]*mixed-port:[[:space:]]*7890[[:space:]]*$' \
        "$MIHOMO_CONFIG" ||
        warn "没有检测到 mixed-port: 7890"


    if grep -Eq \
        '^[[:space:]]*ipv6:[[:space:]]*false[[:space:]]*$' \
        "$MIHOMO_CONFIG"; then

        ok "Mihomo IPv6 = false"

    else

        warn "Mihomo 没有明确设置 ipv6: false"

    fi


    if grep -Eq \
        '^[[:space:]]*dns:[[:space:]]*$' \
        "$MIHOMO_CONFIG"; then

        ok "检测到 DNS 配置"

    else

        warn "没有检测到 DNS 配置"

    fi

}


###############################################################################
# DNS 端口
#
# Mihomo 需要直接监听 53。
#
# systemd-resolved 如果占用 53，会导致：
#
#   bind: address already in use
#
###############################################################################

check_dns_port() {

    log "检查 DNS 53"

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then

        systemctl stop systemd-resolved || true
        systemctl disable systemd-resolved || true

        ok "已停止 systemd-resolved"

    fi


    local result

    result="$(
        ss -lntup 2>/dev/null |
        awk '$5 ~ /:53$/ || $5 ~ /\]:53$/'
    )"


    if [ -n "$result" ]; then

        echo
        echo "$result"
        echo

        #
        # 如果已经是 Mihomo 自己占用，则允许。
        #

        if echo "$result" | grep -q "mihomo"; then

            ok "53 端口已经由 Mihomo 使用"

        else

            die "53 端口仍被其他程序占用"

        fi

    else

        ok "53 端口可用"

    fi

}


###############################################################################
# TProxy 内核支持
###############################################################################

check_tproxy_support() {

    log "检查 nftables TProxy"

    local test_file

    test_file="$(mktemp)"

    cat > "$test_file" <<'EOF'
table ip mihomo_tproxy_test {

    chain prerouting {

        type filter hook prerouting priority mangle;
        policy accept;

        ip protocol tcp \
            tproxy to :7893 \
            meta mark set 0x1 \
            accept;
    }
}
EOF


    if nft -c -f "$test_file" >/tmp/mihomo-tproxy-check.log 2>&1; then

        ok "nftables TProxy 语法正常"

    else

        cat /tmp/mihomo-tproxy-check.log

        rm -f "$test_file"

        die "当前 nftables / 内核不支持该 TProxy 规则"

    fi


    rm -f "$test_file"
    rm -f /tmp/mihomo-tproxy-check.log

}


###############################################################################
# sysctl
###############################################################################

configure_sysctl() {

    log "配置内核参数"

    cat > "$SYSCTL_FILE" <<'EOF'
###############################################################################
# Mihomo Pure TProxy
###############################################################################

# IPv4 forwarding
net.ipv4.ip_forward=1

# TProxy local route
net.ipv4.conf.all.route_localnet=1
net.ipv4.conf.default.route_localnet=1

# 避免 rp_filter 丢弃透明代理流量
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0

# 本方案关闭 IPv6
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF


    sysctl -p "$SYSCTL_FILE" >/dev/null

    ok "sysctl 配置完成"

}




###############################################################################
# 策略路由
###############################################################################

create_policy_script() {

    log "创建策略路由"

    cat > "$POLICY_SCRIPT" <<EOF
#!/bin/bash
set -e

MARK="$MARK"
TABLE="$TABLE"

#
# 删除已有相同 fwmark 规则
#

while ip rule show | grep -Eq "fwmark 0x1.*lookup $TABLE"; do

    ip rule del fwmark 0x1 table "$TABLE" 2>/dev/null || break

done


#
# 清空 table
#

ip route flush table "$TABLE" 2>/dev/null || true


#
# 添加 fwmark → table 100
#

ip rule add fwmark 0x1 table "$TABLE"


#
# TProxy 核心路由
#

ip route add local 0.0.0.0/0 dev lo table "$TABLE"
EOF


    chmod 755 "$POLICY_SCRIPT"

    ok "策略路由脚本完成"

}


###############################################################################
# nftables
#
# 关键设计：
#
# LAN：
#
#   PREROUTING
#       ↓
#   TProxy 7893
#
#
# 本机：
#
#   OUTPUT
#       ↓
#   mark 0x1
#       ↓
#   table 100
#       ↓
#   local dev lo
#       ↓
#   PREROUTING
#       ↓
#   TProxy 7893
#
#
# Mihomo：
#
#   UID mihomo
#       ↓
#   OUTPUT return
#
#
# 非常重要：
#
# PREROUTING 不能使用：
#
#   meta mark & 0x1 == 0x1 return
#
# 否则本机 OUTPUT 打 mark 后重新进入 PREROUTING
# 时会直接 return，无法进入 TProxy。
#
###############################################################################

create_nftables() {

    log "生成 nftables"

    cat > "$NFT_FILE" <<EOF
###############################################################################
# Mihomo Pure TProxy
###############################################################################

table ip mihomo {

    ###########################################################################
    # PREROUTING
    ###########################################################################

    chain prerouting {

        type filter hook prerouting priority mangle;
        policy accept;


        #######################################################################
        # 本地 / 私有地址不代理
        #
        # 注意：
        #
        # 不排除 198.18.0.0/16
        #
        # 因为 Mihomo Fake-IP 使用该地址段。
        #######################################################################

        ip daddr {
            0.0.0.0/8,
            10.0.0.0/8,
            127.0.0.0/8,
            169.254.0.0/16,
            172.16.0.0/12,
            192.168.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        } return;


        #######################################################################
        # LAN TCP
        #######################################################################

        ip saddr $LAN_CIDR \
            meta l4proto tcp \
            tproxy to :$TPROXY_PORT \
            meta mark set $MARK \
            accept;


        #######################################################################
        # LAN UDP
        #######################################################################

        ip saddr $LAN_CIDR \
            meta l4proto udp \
            tproxy to :$TPROXY_PORT \
            meta mark set $MARK \
            accept;


        #######################################################################
        # 本机 OUTPUT → table 100 → PREROUTING
        #
        # 本机 OUTPUT 已经设置 mark 0x1。
        #
        # 经过：
        #
        #   table 100
        #       ↓
        #   local dev lo
        #
        # 后再次进入 PREROUTING。
        #
        # 此时必须送入 TProxy。
        #######################################################################

        meta mark $MARK \
            meta l4proto tcp \
            tproxy to :$TPROXY_PORT \
            meta mark set $MARK \
            accept;


        meta mark $MARK \
            meta l4proto udp \
            tproxy to :$TPROXY_PORT \
            meta mark set $MARK \
            accept;
    }


    ###########################################################################
    # OUTPUT
    ###########################################################################

    chain output {

        type route hook output priority mangle;
        policy accept;


        #######################################################################
        # Mihomo 自己的连接不代理
        #
        # mihomo 用户 UID 通常是 999，但这里使用用户匹配。
        #######################################################################

        meta skuid $MIHOMO_USER return;


        #######################################################################
        # 已经有 mark 的连接不重复处理
        #######################################################################

        meta mark & $MARK == $MARK return;


        #######################################################################
        # 本机目的地址不代理
        #######################################################################

        ip daddr {
            0.0.0.0/8,
            10.0.0.0/8,
            127.0.0.0/8,
            169.254.0.0/16,
            172.16.0.0/12,
            192.168.0.0/16,
            224.0.0.0/4,
            240.0.0.0/4
        } return;


        #######################################################################
        # 本机 TCP
        #######################################################################

        meta l4proto tcp \
            meta mark set $MARK;


        #######################################################################
        # 本机 UDP
        #######################################################################

        meta l4proto udp \
            meta mark set $MARK;
    }
}
EOF


    ok "nftables 规则已生成"

}


###############################################################################
# nftables include
###############################################################################

configure_nft_include() {

    log "配置 nftables include"

    touch /etc/nftables.conf

    if ! grep -Fq \
        'include "/etc/nftables.d/*.nft"' \
        /etc/nftables.conf; then

        cat >> /etc/nftables.conf <<'EOF'

###############################################################################
# Mihomo
###############################################################################

include "/etc/nftables.d/*.nft"
EOF

    fi

    ok "nftables include 已配置"

}


###############################################################################
# nft 配置检查
###############################################################################

check_nft_config() {

    log "检查 nftables 配置"

    nft -c -f /etc/nftables.conf

    ok "nftables 配置正确"

}


###############################################################################
# policy service
###############################################################################

create_policy_service() {

    cat > "$POLICY_SERVICE" <<'EOF'
[Unit]
Description=Mihomo TProxy Policy Routing

Wants=systemd-networkd-wait-online.service

After=systemd-networkd.service
After=systemd-networkd-wait-online.service

Before=mihomo.service

[Service]
Type=oneshot

ExecStart=/usr/local/sbin/mihomo-policy.sh

RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

}


###############################################################################
# Mihomo systemd service
#
# Mihomo 必须以非 root 用户运行。
#
# 但 TProxy 和 53 端口需要特殊权限：
#
#   CAP_NET_ADMIN
#   CAP_NET_RAW
#   CAP_NET_BIND_SERVICE
#
###############################################################################

create_mihomo_service() {

    log "创建 Mihomo systemd"

    cat > "$MIHOMO_SERVICE" <<EOF
[Unit]
Description=Mihomo Pure TProxy Gateway
Wants=network-online.target
After=network-online.target
After=mihomo-policy.service
After=nftables.service
Requires=mihomo-policy.service
Requires=nftables.service

[Service]
Type=simple

User=mihomo
Group=mihomo

ExecStartPre=/usr/local/bin/mihomo -t -d /etc/mihomo
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo

Restart=on-failure
RestartSec=5

LimitNOFILE=1048576

NoNewPrivileges=false

AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

# Mihomo 在 Linux 下进行路由查询需要 AF_NETLINK
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF

    ok "Mihomo systemd 创建完成"

}


###############################################################################
# systemd
###############################################################################

reload_systemd() {

    systemctl daemon-reload

}


enable_services() {

    systemctl enable nftables
    systemctl enable mihomo-policy
    systemctl enable mihomo

    ok "服务已设置开机启动"

}


###############################################################################
# 启动策略
###############################################################################

start_policy() {

    log "启动策略路由"

    systemctl restart mihomo-policy

}


###############################################################################
# 启动 nft
###############################################################################

start_nftables() {

    log "启动 nftables"

    systemctl restart nftables

}


###############################################################################
# 启动 Mihomo
###############################################################################

start_mihomo() {

    log "启动 Mihomo"

    systemctl reset-failed mihomo 2>/dev/null || true

    systemctl restart mihomo

    sleep 3

    if ! systemctl is-active --quiet mihomo; then

        journalctl \
            -u mihomo \
            -n 100 \
            --no-pager

        die "Mihomo 启动失败"

    fi

    ok "Mihomo 正常运行"

}


###############################################################################
# 检查策略路由
###############################################################################

check_policy() {

    log "检查策略路由"

    echo
    echo "========== ip rule =========="

    ip rule


    echo
    echo "========== table 100 =========="

    ip route show table "$TABLE"


    #
    # 检查 fwmark
    #

    ip rule show |
        grep -Eq "fwmark 0x1.*lookup $TABLE" ||
        die "fwmark 策略路由不存在"


    #
    # Linux 不同版本可能显示：
    #
    # local default dev lo
    #
    # 或：
    #
    # local 0.0.0.0/0 dev lo
    #

    ip route show table "$TABLE" |
        grep -Eq '^local (default|0\.0\.0\.0/0).*dev lo' ||
        die "table 100 local route 不存在"


    ok "策略路由正常"

}


###############################################################################
# 检查 nft
###############################################################################

check_nft_runtime() {

    log "检查 nftables 运行状态"

    systemctl is-active --quiet nftables ||
        die "nftables 没有运行"


    nft list table ip mihomo >/dev/null 2>&1 ||
        die "mihomo nft table 不存在"


    nft list table ip mihomo

    ok "nftables 正常"

}


###############################################################################
# 检查 Mihomo
###############################################################################

check_mihomo_runtime() {

    log "检查 Mihomo"

    systemctl is-active --quiet mihomo ||
        die "Mihomo 没有运行"


    ok "Mihomo 正常运行"

}


###############################################################################
# 检查端口
###############################################################################

check_ports() {

    log "检查端口"

    ss -lntup 2>/dev/null |
        grep -E ':(53|7890|7893|9090)\b' ||
        true

}


###############################################################################
# 检查本机透明代理
###############################################################################

check_local_tproxy() {

    log "检查本机 TProxy"

    echo
    echo "========== OUTPUT =========="

    nft list chain ip mihomo output


    echo
    echo "========== PREROUTING =========="

    nft list chain ip mihomo prerouting


    echo
    echo "说明："

    echo "普通本机 TCP/UDP → OUTPUT mark → table 100 → PREROUTING → TProxy"

    echo "Mihomo 自身 → skuid mihomo → return"

    echo "LAN 客户端 → PREROUTING → TProxy"

}


###############################################################################
# DNS 检查
###############################################################################

check_dns() {

    log "检查 Mihomo DNS"

    if ss -lntup 2>/dev/null |
        grep -Eq '(\*|0\.0\.0\.0|\[::\]):53\b.*mihomo'; then

        ok "Mihomo 正在监听 53"

    else

        warn "没有检测到 Mihomo 监听 53"

    fi

}


###############################################################################
# Fake-IP 检查
###############################################################################

check_fake_ip() {

    log "检查 Fake-IP"

    if grep -Eq \
        '198\.18\.0\.0/16|198\.18\.0\.1/16' \
        "$MIHOMO_CONFIG"; then

        ok "检测到 Fake-IP 地址段"

    else

        warn "没有明确检测到 198.18.0.0/16 Fake-IP 配置"

    fi

}


###############################################################################
# 完整检查
###############################################################################

full_check() {

    log "Mihomo Pure TProxy 完整检查"

    check_policy
    check_nft_runtime
    check_mihomo_runtime
    check_ports
    check_dns
    check_fake_ip

    echo
    echo "============================================================"
    echo "             Mihomo Pure TProxy 已运行"
    echo "============================================================"

    echo
    echo "LAN：        $LAN_CIDR"
    echo "Mixed：      $MIXED_PORT"
    echo "TProxy：     $TPROXY_PORT"
    echo "DNS：        $DNS_PORT"
    echo "Controller： $API_PORT"

    echo
    echo "模式："

    echo "  LAN        → PREROUTING → TProxy"
    echo "  本机       → OUTPUT mark → table 100 → TProxy"
    echo "  Mihomo     → UID 排除"
    echo "  TUN        → 不使用"
    echo "  HTTP_PROXY → 不使用"
    echo "  DNS        → Mihomo :53"
    echo "  Fake-IP    → 198.18.0.0/16"

}


###############################################################################
# 卸载
###############################################################################

uninstall() {

    log "卸载 Mihomo Pure TProxy"

    systemctl stop mihomo 2>/dev/null || true
    systemctl stop mihomo-policy 2>/dev/null || true


    systemctl disable mihomo 2>/dev/null || true
    systemctl disable mihomo-policy 2>/dev/null || true


    #
    # 删除策略路由
    #

    while ip rule show |
        grep -Eq "fwmark 0x1.*lookup $TABLE"; do

        ip rule del fwmark 0x1 table "$TABLE" 2>/dev/null ||
            break

    done


    ip route flush table "$TABLE" 2>/dev/null || true


    #
    # 删除 nft
    #

    nft delete table ip mihomo 2>/dev/null || true


    #
    # 删除配置
    #

    rm -f "$NFT_FILE"
    rm -f "$POLICY_SCRIPT"
    rm -f "$POLICY_SERVICE"
    rm -f "$MIHOMO_SERVICE"
    rm -f "$SYSCTL_FILE"


    #
    # 恢复 IPv4
    #

    sysctl -w net.ipv4.ip_forward=0 \
        >/dev/null 2>&1 || true

    sysctl -w net.ipv4.conf.all.route_localnet=0 \
        >/dev/null 2>&1 || true

    sysctl -w net.ipv4.conf.default.route_localnet=0 \
        >/dev/null 2>&1 || true

    sysctl -w net.ipv4.conf.all.rp_filter=1 \
        >/dev/null 2>&1 || true

    sysctl -w net.ipv4.conf.default.rp_filter=1 \
        >/dev/null 2>&1 || true


    #
    # 恢复 IPv6
    #

    sysctl -w net.ipv6.conf.all.disable_ipv6=0 \
        >/dev/null 2>&1 || true

    sysctl -w net.ipv6.conf.default.disable_ipv6=0 \
        >/dev/null 2>&1 || true


    systemctl daemon-reload

    ok "TProxy 已卸载"

}


###############################################################################
# 安装
###############################################################################

install_main() {

    log "Mihomo Pure TProxy Gateway"

    echo "LAN：        $LAN_CIDR"
    echo "Mixed：      $MIXED_PORT"
    echo "TProxy：     $TPROXY_PORT"
    echo "DNS：        $DNS_PORT"
    echo "Controller： $API_PORT"
    echo "Mark：       $MARK"
    echo "Table：      $TABLE"

    echo
    echo "LAN + 本机：透明代理"
    echo "TUN：        不使用"
    echo "HTTP_PROXY：不使用"
    echo "DNS：        Mihomo :53"
    echo "Fake-IP：    198.18.0.0/16"


    check_root
    detect_arch
    check_system

    install_dependencies

    create_directories

    #
    # 必须先创建用户，再安装 config。
    #

    create_mihomo_user

    check_dns_port

    install_mihomo

    install_config

    check_config
    check_required_config

    check_tproxy_support

    configure_sysctl

    create_policy_script

    create_nftables

    configure_nft_include

    check_nft_config

    create_policy_service

    create_mihomo_service

    reload_systemd

    enable_services

    start_policy

    start_nftables

    start_mihomo

    full_check


    log "安装完成"

    echo
    echo "客户端设置："

    echo
    echo "1. 网关设置为本机 LAN 地址"
    echo "2. DNS 设置为本机 LAN 地址"
    echo "3. 不需要设置 HTTP/SOCKS 代理"

    echo
    echo "本机程序："

    echo "不需要设置 HTTP_PROXY"
    echo "不需要设置 HTTPS_PROXY"

    echo
    echo "DNS："

    echo "本机：Mihomo :53"
    echo "客户端：使用本机 LAN 地址 :53"

    echo
    echo "实时日志："

    echo "journalctl -u mihomo -f"

    echo
    echo "检查："

    echo "$0 check"

}


###############################################################################
# 参数
###############################################################################

case "$ACTION" in

    install)

        check_root
        install_main

        ;;


    check)

        check_root
        full_check

        ;;


    uninstall)

        check_root
        uninstall

        ;;


    help|-h|--help)

        echo
        echo "用法："
        echo
        echo "  $0"
        echo "      安装 / 更新"
        echo
        echo "  $0 check"
        echo "      检查运行状态"
        echo
        echo "  $0 uninstall"
        echo "      卸载"
        echo

        ;;


    *)

        echo "未知参数：$ACTION"
        exit 1

        ;;

esac