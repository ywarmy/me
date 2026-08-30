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
#   LAN       自动获取
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SOURCE="${SCRIPT_DIR}/config.yaml"
GITHUB_PROXY_URLS="${GITHUB_PROXY_URLS:-https://ghproxy.net https://ghproxy.homeboyc.cn https://ghfast.top}"
GITHUB_RELEASE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
RELEASE_METADATA_FILE=""
MIHOMO_LATEST_VERSION=""

MIHOMO_DIR="/etc/mihomo"
MIHOMO_CONFIG="${MIHOMO_DIR}/config.yaml"

BACKUP_DIR="/root/mihomo-backups"

NFT_DIR="/etc/nftables.d"
NFT_FILE="${NFT_DIR}/mihomo-tproxy.nft"

POLICY_SCRIPT="/usr/local/sbin/mihomo-policy.sh"

POLICY_SERVICE="/etc/systemd/system/mihomo-policy.service"
MIHOMO_SERVICE="/etc/systemd/system/mihomo.service"

SYSCTL_FILE="/etc/sysctl.d/99-mihomo-tproxy.conf"
SYSCTL_BACKUP_FILE="${BACKUP_DIR}/sysctl.before-mihomo"

LAN_IF=""
LAN_IP_CIDR=""
LAN_CIDR=""

RESOLV_CONF="/etc/resolv.conf"
RESOLV_BACKUP_FILE="${BACKUP_DIR}/resolv.conf.before-mihomo"
RESOLVED_STATE_FILE="${BACKUP_DIR}/systemd-resolved.state"
NFT_CONF_BACKUP_FILE="${BACKUP_DIR}/nftables.conf.before-mihomo"

MIXED_PORT="7890"
TPROXY_PORT="7893"
DNS_PORT="53"
API_PORT="9090"

MARK="0x1"
TABLE="100"
RULE_PRIORITY="10000"

MIHOMO_USER="mihomo"
MIHOMO_GROUP="mihomo"

# 不带参数时进入交互菜单；带参数时保留命令行模式，便于自动化调用。
ACTION="${1:-menu}"

CONFIG_CHANGED=0
SYSCTL_CHANGED=0
NFT_CHANGED=0
POLICY_CHANGED=0
SYSTEMD_CHANGED=0
MIHOMO_CHANGED=0
DNS_CHANGED=0


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
    restore_dns_state 2>/dev/null || true
    echo
    echo "[ERROR] $1"

    #
    # 已经写入系统的组件（nft / 服务 / 二进制）不做自动回滚：
    # 远程自动清理防火墙和策略路由可能导致失联，
    # 这里只尝试恢复 DNS，并提示如何完整清理。
    #

    if [ -f "$MIHOMO_SERVICE" ] || [ -f "$POLICY_SERVICE" ]; then
        echo
        echo "注意：部分组件已写入系统（DNS/sysctl 已尝试恢复）。"
        echo "如需完整清理，请运行：$0 uninstall"
    fi

    exit 1
}

write_file_if_changed() {

    local SOURCE="$1"
    local TARGET="$2"
    local MODE="${3:-644}"

    if [ -f "$TARGET" ] && cmp -s "$SOURCE" "$TARGET"; then
        rm -f "$SOURCE"
        return 1
    fi

    install -m "$MODE" "$SOURCE" "$TARGET"
    rm -f "$SOURCE"
    return 0
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

detect_lan_network() {

    log "识别 LAN 网卡和网段"

    local default_if=""
    local candidate_if=""
    local candidate_cidr=""

    default_if="$(
        ip -4 route show default 2>/dev/null |
        awk 'NR==1 {for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
    )"

    # 网关设备通常同时有 WAN 和 LAN 网卡。优先选择带私网 IPv4 的网卡，
    # 没有私网网卡时再回退到默认路由网卡。
    LAN_IF=""
    while read -r candidate_if candidate_cidr; do
        case "$candidate_cidr" in
            10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
                LAN_IF="$candidate_if"
                break
                ;;
        esac
    done < <(
        ip -o -4 addr show scope global 2>/dev/null |
        awk '$3 == "inet" {print $2, $4}' || true
    )

    [ -n "$LAN_IF" ] || LAN_IF="$default_if"

    [ -n "$LAN_IF" ] || die "没有找到默认路由网卡"

    LAN_IP_CIDR="$(
        ip -o -4 addr show dev "$LAN_IF" scope global 2>/dev/null |
        awk 'NR==1 {print $4}'
    )"

    [ -n "$LAN_IP_CIDR" ] ||
        die "网卡 $LAN_IF 没有可用的全局 IPv4 地址"

    LAN_CIDR="$(
        ip -4 route show dev "$LAN_IF" scope link 2>/dev/null |
        awk '$1 ~ /^[0-9]+(\.[0-9]+){3}\/[0-9]+$/ {print $1; exit}'
    )"

    [ -n "$LAN_CIDR" ] ||
        die "无法从 $LAN_IF 识别直连 LAN 网段（当前地址：$LAN_IP_CIDR）"

    ok "LAN 网卡：$LAN_IF"
    ok "LAN 网段：$LAN_CIDR"
}


###############################################################################
# 依赖
###############################################################################

install_dependencies() {

    log "安装依赖"

    local package=""
    local missing_packages=()

    for package in curl wget jq nftables iproute2 ca-certificates gzip procps passwd iputils-ping coreutils; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null |
             grep -q 'install ok installed'; then
            missing_packages+=("$package")
        fi
    done

    if [ "${#missing_packages[@]}" -eq 0 ]; then
        ok "依赖已安装，跳过 apt update/install"
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive

    apt update

    apt install -y "${missing_packages[@]}"

    ok "缺失依赖已安装：${missing_packages[*]}"

}

check_runtime_dependencies() {

    local cmd=""

    for cmd in ip ss nft jq curl wget gzip sysctl mktemp install \
        sha256sum groupadd useradd getent journalctl ping sort; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "缺少必要命令：$cmd"
    done

    ok "运行时依赖检查通过"
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

fetch_release_metadata() {

    local url="$1"
    local output_file="$2"

    rm -f "$output_file"

    curl -fsSL \
        --connect-timeout 10 \
        --max-time 30 \
        "$url" > "$output_file" || return 1

    jq -e '.tag_name and (.assets | type == "array")' "$output_file" \
        >/dev/null 2>&1 || {
        rm -f "$output_file"
        return 1
    }
}

get_latest_version() {

    #
    # 注意：
    #
    # 本函数必须在当前 shell 中直接调用，
    # 不能放在 $( ) 命令替换中。
    #
    # 否则 RELEASE_METADATA_FILE / MIHOMO_LATEST_VERSION
    # 无法传回父 shell，SHA256 校验会被静默跳过。
    #

    local proxy_base=""
    local proxy_url=""

    RELEASE_METADATA_FILE="$(mktemp /tmp/mihomo-release.XXXXXX.json)"

    if fetch_release_metadata "$GITHUB_RELEASE_API" "$RELEASE_METADATA_FILE"; then
        ok "GitHub API 直连成功"
    else
        warn "GitHub API 直连失败，开始尝试代理"

        for proxy_base in $GITHUB_PROXY_URLS; do
            proxy_url="${proxy_base%/}/$GITHUB_RELEASE_API"

            if fetch_release_metadata "$proxy_url" "$RELEASE_METADATA_FILE"; then
                ok "GitHub API 代理成功：$proxy_base"
                break
            fi

            warn "GitHub API 代理不可用：$proxy_base"
        done
    fi

    MIHOMO_LATEST_VERSION="$(jq -er '.tag_name' "$RELEASE_METADATA_FILE")" ||
        die "无法获取 Mihomo 最新版本信息"
}


get_current_version() {

    [ -x "$MIHOMO_BIN" ] || return 0

    "$MIHOMO_BIN" -v 2>/dev/null |
        grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' |
        head -n 1 ||
        true

}

get_release_sha256() {

    local asset_name="$1"

    [ -f "$RELEASE_METADATA_FILE" ] || return 1

    jq -er --arg name "$asset_name" '
        .assets[]
        | select(.name == $name)
        | (.digest // "")
        | sub("^sha256:"; "")
        | select(length > 0)
    ' "$RELEASE_METADATA_FILE"
}

download_release() {

    local url="$1"
    local output_file="$2"
    local expected_sha256="${3:-}"
    local actual_sha256=""

    rm -f "$output_file"

    if ! wget \
        --timeout=30 \
        --tries=3 \
        -O "$output_file" \
        "$url"; then
        rm -f "$output_file"
        return 1
    fi

    if ! gzip -t "$output_file" >/dev/null 2>&1; then
        rm -f "$output_file"
        return 1
    fi

    if [ -n "$expected_sha256" ]; then
        actual_sha256="$(sha256sum "$output_file" | awk '{print $1}')"

        if [ "$actual_sha256" != "$expected_sha256" ]; then
            rm -f "$output_file"
            return 1
        fi
    fi
}


install_mihomo() {

    log "安装 / 更新 Mihomo"

    local current=""
    local latest=""
    local url=""
    local proxy_url=""
    local proxy_base=""
    local proxy_downloaded=0
    local download_dir=""
    local old_backup=""
    local asset_name=""
    local expected_sha256=""

    current="$(get_current_version)"

    get_latest_version
    latest="$MIHOMO_LATEST_VERSION"

    echo "当前版本：${current:-未安装}"
    echo "最新版本：$latest"

    if [ "$current" = "$latest" ]; then

        rm -f "$RELEASE_METADATA_FILE"
        RELEASE_METADATA_FILE=""

        ok "Mihomo 已经是最新版"

        return

    fi

    url="https://github.com/MetaCubeX/mihomo/releases/download/${latest}/mihomo-linux-${ARCH}-${latest}.gz"
    asset_name="mihomo-linux-${ARCH}-${latest}.gz"
    expected_sha256="$(get_release_sha256 "$asset_name" || true)"

    if [ -n "$expected_sha256" ]; then
        ok "已获取 Release SHA256 校验值"
    else
        warn "Release API 没有提供 SHA256，跳过哈希校验"
    fi

    rm -f "$RELEASE_METADATA_FILE"
    RELEASE_METADATA_FILE=""

    echo
    echo "下载："
    echo "$url"

    download_dir="$(mktemp -d /tmp/mihomo-install.XXXXXX)"

    cleanup_download_dir() {
        rm -rf "$download_dir"
    }

    if download_release "$url" "${download_dir}/mihomo.gz" "$expected_sha256"; then
        ok "GitHub 直连下载成功"
    else
        warn "GitHub 直连下载失败，开始尝试代理"

        for proxy_base in $GITHUB_PROXY_URLS; do
            proxy_url="${proxy_base%/}/$url"

            echo "尝试代理：$proxy_base"

            if download_release "$proxy_url" "${download_dir}/mihomo.gz" "$expected_sha256"; then
                ok "GitHub 代理下载成功：$proxy_base"
                proxy_downloaded=1
                break
            fi

            warn "代理不可用或返回内容无效：$proxy_base"
        done

        [ "$proxy_downloaded" -eq 1 ] || {
            cleanup_download_dir
            die "GitHub 直连和所有代理下载均失败"
        }
    fi

    gzip -d "${download_dir}/mihomo.gz"

    [ -f "${download_dir}/mihomo" ] || {
        cleanup_download_dir
        die "Mihomo 解压失败"
    }

    chmod 755 "${download_dir}/mihomo"

    "${download_dir}/mihomo" -v >/dev/null 2>&1 || {
        cleanup_download_dir
        die "Mihomo 无法运行"
    }

    if [ -x "$MIHOMO_BIN" ]; then
        old_backup="${BACKUP_DIR}/mihomo.$(date +%Y%m%d-%H%M%S)"
        cp -a "$MIHOMO_BIN" "$old_backup"
        ok "旧 Mihomo 已备份：$old_backup"
    fi

    install -m 755 "${download_dir}/mihomo" "${MIHOMO_BIN}.new"
    mv -f "${MIHOMO_BIN}.new" "$MIHOMO_BIN"
    MIHOMO_CHANGED=1

    cleanup_download_dir

    ok "Mihomo 安装完成"

    "$MIHOMO_BIN" -v || true

}


###############################################################################
# 配置
###############################################################################

create_embedded_config() {

    local TARGET="$1"
    local SUBSCRIPTION_URL="$2"

    cat > "$TARGET" <<'EOF'
proxy-providers:
  Airport1:
EOF

    printf '%s' '    url: "' >> "$TARGET"
    printf '%s' "$SUBSCRIPTION_URL" >> "$TARGET"
    printf '%s\n' '"' >> "$TARGET"

    cat >> "$TARGET" <<'EOF'
    type: http
    interval: 864000
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
    proxy: 🎯direct
# 节点信息
proxies:
  - {name: 🎯direct, type: direct, udp: true}

# 全局配置 
mixed-port: 7890
tproxy-port: 7893
allow-lan: true
bind-address: "*"
ipv6: false
unified-delay: true
tcp-concurrent: true
log-level: warning
find-process-mode: 'off'
# interface-name: en0
keep-alive-idle: 600
keep-alive-interval: 15
disable-keep-alive: false
profile:
  store-selected: true
  store-fake-ip: true

# 控制面板
external-controller: 0.0.0.0:9090
secret: ""
external-ui: "/etc/mihomo/ui"
external-ui-name: zashboard
external-ui-url: "https://github.com/Zephyruso/zashboard/archive/refs/heads/gh-pages.zip"

# 嗅探
sniffer:
  enable: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]
  skip-domain:
    - "rule-set:private_domain,cn_domain"
    - "dlg.io.mi.com"
    - "+.push.apple.com"
    - "+.apple.com"
    - "+.wechat.com"
    - "+.qpic.cn"
    - "+.qq.com"
    - "+.wechatapp.com"
    - "+.vivox.com"
    - "+.oray.com"
    - "+.sunlogin.net"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"


hosts:
  doh.pub: [1.12.12.12, 120.53.53.53]
  dns.alidns.com: [223.5.5.5, 223.6.6.6]
  dns.google: [8.8.8.8, 8.8.4.4]
  cloudflare-dns.com: [1.1.1.1, 1.0.0.1]
# DNS模块
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false
  respect-rules: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    - "rule-set:private_domain,cn_domain"
    - "+.services.googleapis.cn"
    - "+.xn--ngstr-lra8j.com"
    - "time.*.com"
    - "+.pool.ntp.org"
    - "+.ntp.tencent.com"
    - "+.ntp1.aliyun.com"
    - "+.ntp.ntsc.ac.cn"
    - "+.cn.ntp.org.cn"
  nameserver:
    - https://cloudflare-dns.com/dns-query
    - https://dns.google/dns-query
  proxy-server-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
  direct-nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
# 出站策略
# 注意锚点必须放在引用的上方，可以集中把锚点全部放yaml的顶部。
pr: &pr {type: select, proxies: [🚀Proxy]}
proxy-groups:
  - {name: 🚀Proxy, type: select, proxies: [♻️代理节点, 🌐全部节点]}
  - {name: ♻️代理节点, type: url-test, use: [Airport1], tolerance: 20, interval: 300, filter: "^(?=.*(B1|B2|SG|JP|TW)).*$"}
  - {name: 🌐全部节点, type: url-test, include-all: true, exclude-type: direct, tolerance: 20, interval: 300}

# 规则匹配
# 此规则部分没有做防泄露处理，因为弊严重大于利！
rules:
# - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT-DROP
  - RULE-SET,apple_domain,🎯direct
  - RULE-SET,gfw_domain,🚀Proxy
  - RULE-SET,telegram_domain,🚀Proxy
  - RULE-SET,geolocation-!cn,🚀Proxy
  - RULE-SET,telegram_ip,🚀Proxy,no-resolve
  - RULE-SET,private_domain,🎯direct
  - RULE-SET,cn_domain,🎯direct
  - RULE-SET,cn_ip,🎯direct
  - MATCH,🚀Proxy

# 规则集
rule-anchor:
  ip: &ip {type: http, interval: 86400, behavior: ipcidr, format: mrs}
  domain: &domain {type: http, interval: 86400, behavior: domain, format: mrs}
  class: &class {type: http, interval: 86400, behavior: classical, format: text}
  keyword: &keyword {type: http, interval: 86400, behavior: classical, format: text}
rule-providers: 
  apple_domain: {<<: *class, url: "https://raw.githubusercontent.com/ywarmy/me/refs/heads/main/cn.list"}
  telegram_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/telegram.mrs"}
  private_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/private.mrs"}
  gfw_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/gfw.mrs"}
  geolocation-!cn: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/geolocation-!cn.mrs"}
  cn_domain: { <<: *domain, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs"}
  telegram_ip: { <<: *ip, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/telegram.mrs"}
  cn_ip: { <<: *ip, url: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/cn.mrs"}

EOF
}


install_config() {

    log "安装 config.yaml"

    local CONFIG_TO_INSTALL="$CONFIG_SOURCE"
    local GENERATED_CONFIG=""
    local SUBSCRIPTION_URL=""

    if [ ! -f "$CONFIG_SOURCE" ]; then
        echo
        echo "脚本目录没有 config.yaml，将使用内置配置模板。"
        echo "请输入 Airport1 订阅地址。"
        echo "示例：https://www.xxx.com/mih014/3.....5415/"
        echo

        while true; do
            read -r -p "Airport1 URL：" SUBSCRIPTION_URL

            if [[ "$SUBSCRIPTION_URL" =~ ^https?://[^[:space:]\"\\]+$ ]]; then
                break
            fi

            warn "订阅地址必须以 http:// 或 https:// 开头，且不能包含空格、引号或反斜杠。"
        done

        GENERATED_CONFIG="$(mktemp /tmp/mihomo-config.XXXXXX)"
        create_embedded_config "$GENERATED_CONFIG" "$SUBSCRIPTION_URL"
        CONFIG_TO_INSTALL="$GENERATED_CONFIG"
    fi

    if [ -f "$MIHOMO_CONFIG" ] && cmp -s "$CONFIG_TO_INSTALL" "$MIHOMO_CONFIG"; then
        [ -n "$GENERATED_CONFIG" ] && rm -f "$GENERATED_CONFIG"
        ok "config.yaml 未变化，跳过覆盖"
        CONFIG_CHANGED=0
        return 0
    fi

    if [ -f "$MIHOMO_CONFIG" ]; then

        local backup

        backup="${BACKUP_DIR}/config.yaml.$(date +%Y%m%d-%H%M%S)"

        cp -a "$MIHOMO_CONFIG" "$backup"

        ok "旧配置已备份：$backup"

    fi

    cp -f "$CONFIG_TO_INSTALL" "$MIHOMO_CONFIG"

    [ -n "$GENERATED_CONFIG" ] && rm -f "$GENERATED_CONFIG"

    chown "$MIHOMO_USER:$MIHOMO_GROUP" "$MIHOMO_CONFIG" 2>/dev/null || true

    chmod 600 "$MIHOMO_CONFIG"
    CONFIG_CHANGED=1

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
        "^[[:space:]]*tproxy-port:[[:space:]]*${TPROXY_PORT}[[:space:]]*$" \
        "$MIHOMO_CONFIG" ||
        die "config.yaml 必须设置：tproxy-port: $TPROXY_PORT"

    ok "tproxy-port = $TPROXY_PORT"


    grep -Eq \
        "^[[:space:]]*mixed-port:[[:space:]]*${MIXED_PORT}[[:space:]]*$" \
        "$MIHOMO_CONFIG" ||
        warn "没有检测到 mixed-port: $MIXED_PORT"


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

save_dns_state() {

    mkdir -p "$BACKUP_DIR"

    if [ ! -e "$RESOLV_BACKUP_FILE" ] && [ ! -L "$RESOLV_BACKUP_FILE" ] &&
       { [ -e "$RESOLV_CONF" ] || [ -L "$RESOLV_CONF" ]; }; then
        cp -a "$RESOLV_CONF" "$RESOLV_BACKUP_FILE"
    fi

    if [ ! -f "$RESOLVED_STATE_FILE" ]; then
        local active=0
        local enabled=0
        local resolv_exists=0

        systemctl is-active --quiet systemd-resolved 2>/dev/null && active=1 || true
        systemctl is-enabled --quiet systemd-resolved 2>/dev/null && enabled=1 || true
        if [ -e "$RESOLV_CONF" ] || [ -L "$RESOLV_CONF" ]; then
            resolv_exists=1
        fi

        printf '%s %s %s\n' "$active" "$enabled" "$resolv_exists" > "$RESOLVED_STATE_FILE"
    fi
}

restore_dns_state() {

    local active=0
    local enabled=0
    local resolv_exists=1

    if [ -f "$RESOLV_BACKUP_FILE" ] || [ -L "$RESOLV_BACKUP_FILE" ]; then
        rm -f "$RESOLV_CONF"
        cp -a "$RESOLV_BACKUP_FILE" "$RESOLV_CONF"
    fi

    if [ -f "$RESOLVED_STATE_FILE" ]; then
        read -r active enabled resolv_exists < "$RESOLVED_STATE_FILE" || true

        if [ "$enabled" = "1" ]; then
            systemctl enable systemd-resolved >/dev/null 2>&1 || true
        else
            systemctl disable systemd-resolved >/dev/null 2>&1 || true
        fi

        if [ "$active" = "1" ]; then
            systemctl start systemd-resolved >/dev/null 2>&1 || true
        else
            systemctl stop systemd-resolved >/dev/null 2>&1 || true
        fi

        if [ "$resolv_exists" = "0" ] &&
           [ ! -f "$RESOLV_BACKUP_FILE" ] && [ ! -L "$RESOLV_BACKUP_FILE" ]; then
            rm -f "$RESOLV_CONF"
        fi
    fi
}

configure_local_dns() {

    local temp_file=""

    temp_file="$(mktemp /etc/.resolv.conf.XXXXXX)"
    printf '%s\n' '# Mihomo local DNS' 'nameserver 127.0.0.1' > "$temp_file"
    chmod 644 "$temp_file"

    if [ -f "$RESOLV_CONF" ] && [ ! -L "$RESOLV_CONF" ] &&
       cmp -s "$temp_file" "$RESOLV_CONF"; then
        rm -f "$temp_file"
        ok "本机 DNS 未变化，跳过写入"
        return 0
    fi

    #
    # 如果是软链接（例如指向 systemd-resolved 的 stub-resolv.conf），
    # 显式删除链接后写入普通文件，
    # 避免依赖 mv 对软链接的隐式替换行为。
    # 原始文件已在 save_dns_state 中备份，卸载时可以恢复。
    #

    if [ -L "$RESOLV_CONF" ]; then
        rm -f "$RESOLV_CONF"
        warn "resolv.conf 是软链接，已替换为普通文件（原链接已备份，卸载时可恢复）"
    fi

    mv -f "$temp_file" "$RESOLV_CONF"
    DNS_CHANGED=1

    ok "本机 DNS 已设置为 127.0.0.1"
}

check_dns_port() {

    log "检查 DNS 53"

    save_dns_state

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
    local log_file

    test_file="$(mktemp)"
    log_file="$(mktemp)"

    cat > "$test_file" <<EOF
table ip mihomo_tproxy_test {

    chain prerouting {

        type filter hook prerouting priority mangle;
        policy accept;

        ip protocol tcp \
            tproxy to :$TPROXY_PORT \
            meta mark set $MARK \
            accept;
    }
}
EOF


    if nft -c -f "$test_file" >"$log_file" 2>&1; then

        ok "nftables TProxy 语法正常"

    else

        cat "$log_file"

        rm -f "$test_file"
        rm -f "$log_file"

        die "当前 nftables / 内核不支持该 TProxy 规则"

    fi


    rm -f "$test_file"
    rm -f "$log_file"

}


###############################################################################
# sysctl
###############################################################################

save_sysctl_state() {

    if [ -f "$SYSCTL_BACKUP_FILE" ]; then
        if [ -n "$LAN_IF" ] &&
           ! grep -qF "net.ipv4.conf.${LAN_IF}.rp_filter=" "$SYSCTL_BACKUP_FILE"; then
            local existing_value=""

            existing_value="$(sysctl -n "net.ipv4.conf.${LAN_IF}.rp_filter" 2>/dev/null || true)"
            printf 'net.ipv4.conf.%s.rp_filter=%s\n' "$LAN_IF" "$existing_value" \
                >> "$SYSCTL_BACKUP_FILE"

            existing_value="$(sysctl -n "net.ipv4.conf.${LAN_IF}.route_localnet" 2>/dev/null || true)"
            printf 'net.ipv4.conf.%s.route_localnet=%s\n' "$LAN_IF" "$existing_value" \
                >> "$SYSCTL_BACKUP_FILE"
        fi
        return 0
    fi

    local key=""
    local value=""

    : > "$SYSCTL_BACKUP_FILE"

    for key in \
        net.ipv4.ip_forward \
        net.ipv4.conf.all.route_localnet \
        net.ipv4.conf.default.route_localnet \
        net.ipv4.conf.all.rp_filter \
        net.ipv4.conf.default.rp_filter \
        net.ipv6.conf.all.disable_ipv6 \
        net.ipv6.conf.default.disable_ipv6; do

        value="$(sysctl -n "$key" 2>/dev/null || true)"
        printf '%s=%s\n' "$key" "$value" >> "$SYSCTL_BACKUP_FILE"
    done

    if [ -n "$LAN_IF" ]; then
        for key in \
            "net.ipv4.conf.${LAN_IF}.rp_filter" \
            "net.ipv4.conf.${LAN_IF}.route_localnet"; do
            value="$(sysctl -n "$key" 2>/dev/null || true)"
            printf '%s=%s\n' "$key" "$value" >> "$SYSCTL_BACKUP_FILE"
        done
    fi
}

restore_sysctl_state() {

    local key=""
    local value=""

    if [ -f "$SYSCTL_BACKUP_FILE" ]; then
        while IFS='=' read -r key value; do
            [ -n "$key" ] || continue
            sysctl -w "$key=$value" >/dev/null 2>&1 || true
        done < "$SYSCTL_BACKUP_FILE"
    fi
}

configure_sysctl() {

    log "配置内核参数"

    local temp_file=""

    save_sysctl_state

    temp_file="$(mktemp /tmp/mihomo-sysctl.XXXXXX)"

    cat > "$temp_file" <<'EOF'
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

    if [ -n "$LAN_IF" ]; then
        cat >> "$temp_file" <<EOF

# LAN interface-specific TProxy parameters
net.ipv4.conf.${LAN_IF}.rp_filter=0
net.ipv4.conf.${LAN_IF}.route_localnet=1
EOF
    fi

    if write_file_if_changed "$temp_file" "$SYSCTL_FILE" 644; then
        SYSCTL_CHANGED=1
        sysctl -p "$SYSCTL_FILE" >/dev/null
        ok "sysctl 配置已更新"
    else
        ok "sysctl 配置未变化，跳过写入"
    fi

}




###############################################################################
# 策略路由
###############################################################################

create_policy_script() {

    log "创建策略路由"

    local temp_file=""
    temp_file="$(mktemp /tmp/mihomo-policy.XXXXXX)"

    cat > "$temp_file" <<EOF
#!/bin/bash
set -e

MARK="$MARK"
TABLE="$TABLE"
RULE_PRIORITY="$RULE_PRIORITY"

#
# 删除已有相同 fwmark 规则
#

while ip rule show | grep -Eq "fwmark ${MARK}.*lookup ${TABLE}"; do

    ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null || break

done


#
# 清空 table
#

ip route flush table "$TABLE" 2>/dev/null || true


#
# 添加 fwmark → table 100
#

ip rule add pref "$RULE_PRIORITY" fwmark "$MARK" table "$TABLE"


#
# TProxy 核心路由
#

ip route add local 0.0.0.0/0 dev lo table "$TABLE"
EOF

    if write_file_if_changed "$temp_file" "$POLICY_SCRIPT" 755; then
        POLICY_CHANGED=1
        ok "策略路由脚本已更新"
    else
        ok "策略路由脚本未变化，跳过写入"
    fi

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

    local temp_file=""
    temp_file="$(mktemp /tmp/mihomo-tproxy.XXXXXX)"

    cat > "$temp_file" <<EOF
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

    if write_file_if_changed "$temp_file" "$NFT_FILE" 644; then
        NFT_CHANGED=1
        ok "nftables 规则已更新"
    else
        ok "nftables 规则未变化，跳过写入"
    fi

}


###############################################################################
# nftables include
###############################################################################

configure_nft_include() {

    log "配置 nftables include"

    local include_changed=0

    if [ -f /etc/nftables.conf ] && [ ! -f "$NFT_CONF_BACKUP_FILE" ]; then
        cp -a /etc/nftables.conf "$NFT_CONF_BACKUP_FILE"
    fi

    if [ ! -e /etc/nftables.conf ]; then
        touch /etc/nftables.conf
        include_changed=1
    fi

    if ! grep -Fq \
        'include "/etc/nftables.d/*.nft"' \
        /etc/nftables.conf; then

        cat >> /etc/nftables.conf <<'EOF'

###############################################################################
# Mihomo
###############################################################################

include "/etc/nftables.d/*.nft"
EOF

        include_changed=1

    fi

    [ "$include_changed" -eq 1 ] && NFT_CHANGED=1

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

    local temp_file=""
    temp_file="$(mktemp /tmp/mihomo-policy-service.XXXXXX)"

    cat > "$temp_file" <<'EOF'
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

    if write_file_if_changed "$temp_file" "$POLICY_SERVICE" 644; then
        SYSTEMD_CHANGED=1
        ok "策略 systemd 服务已更新"
    else
        ok "策略 systemd 服务未变化，跳过写入"
    fi

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

    local temp_file=""
    temp_file="$(mktemp /tmp/mihomo-service.XXXXXX)"

    cat > "$temp_file" <<EOF
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

    if write_file_if_changed "$temp_file" "$MIHOMO_SERVICE" 644; then
        SYSTEMD_CHANGED=1
        ok "Mihomo systemd 服务已更新"
    else
        ok "Mihomo systemd 服务未变化，跳过写入"
    fi

}


###############################################################################
# systemd
###############################################################################

reload_systemd() {

    if [ "$SYSTEMD_CHANGED" -eq 1 ]; then
        systemctl daemon-reload
        ok "systemd 配置已重新加载"
    else
        ok "systemd 配置未变化，跳过 daemon-reload"
    fi

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

    if [ "$POLICY_CHANGED" -eq 0 ] &&
       [ "$SYSTEMD_CHANGED" -eq 0 ] &&
       systemctl is-active --quiet mihomo-policy; then
        ok "策略路由服务正常，跳过重启"
        return 0
    fi

    systemctl restart mihomo-policy
    ok "策略路由服务已启动/重启"

}


###############################################################################
# 启动 nft
###############################################################################

start_nftables() {

    log "启动 nftables"

    if [ "$NFT_CHANGED" -eq 0 ] &&
       systemctl is-active --quiet nftables; then
        ok "nftables 正常，跳过重启"
        return 0
    fi

    systemctl restart nftables
    ok "nftables 已启动/重启"

}


###############################################################################
# 启动 Mihomo
###############################################################################

start_mihomo() {

    log "启动 Mihomo"

    systemctl reset-failed mihomo 2>/dev/null || true

    if [ "$MIHOMO_CHANGED" -eq 0 ] &&
       [ "$CONFIG_CHANGED" -eq 0 ] &&
       [ "$SYSTEMD_CHANGED" -eq 0 ] &&
       systemctl is-active --quiet mihomo; then
        ok "Mihomo 正常运行，跳过重启"
        return 0
    fi

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
        grep -Eq "fwmark ${MARK}.*lookup $TABLE" ||
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
        grep -E ":(${DNS_PORT}|${MIXED_PORT}|${TPROXY_PORT}|${API_PORT})\\b" ||
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
# 完整健康检查（由 check.sh 整合）
###############################################################################

health_check() {

    local RED='\033[31m'
    local GREEN='\033[32m'
    local YELLOW='\033[33m'
    local CYAN='\033[36m'
    local BLUE='\033[34m'
    local RESET='\033[0m'
    local HEALTH_SERVICE="mihomo"
    local DNS_TEST_DOMAIN="${MIHOMO_DNS_TEST_DOMAIN:-www.baidu.com}"
    local HTTPS_TEST_URL="${MIHOMO_HTTPS_TEST_URL:-https://www.baidu.com}"
    local DEFAULT_TPROXY_PORT="7893"
    local DEFAULT_API_PORT="9090"
    local PASS=0
    local FAIL=0
    local WARN=0
    local INFO_COUNT=0

    #
    # 以下变量会在检查过程中被重新探测赋值。
    # 必须全部声明为 local，避免覆盖脚本级配置：
    # 否则菜单中先「检测运行状态」再「卸载」时，
    # 卸载会使用探测值（可能为空或不同）而非安装时的配置值，
    # 导致 fwmark 规则 / 路由表残留。
    #

    local REQUIRED_TOOLS=""
    local DEFAULT_ROUTE=""
    local LAN_IF=""
    local LAN_IP=""
    local LAN_CIDR=""
    local GATEWAY=""
    local IP_FORWARD=""
    local RP_ALL=""
    local RP_DEFAULT=""
    local RP_IF=""
    local SRC_VALID_MARK=""
    local ROUTE_LOCALNET=""
    local POLICY_LINE=""
    local MARK=""
    local TABLE=""
    local TEST_IP=""
    local MARK_ROUTE=""
    local NFT_TABLES=""
    local NFT_FAMILY=""
    local NFT_TABLE=""
    local NFT_RULES=""
    local TPROXY_PORT=""
    local PREROUTING_BLOCK=""
    local NFT_OUTPUT=""
    local OUTPUT_MARK_ROUTE=""
    local MIHOMO_PID=""
    local MIHOMO_UID=""
    local CONFIG_FILE=""
    local CONFIG_API=""
    local API_PORT=""
    local DNS_RESULT=""
    local HTTP_CODE=""
    local PROXY_ENV=0
    local V=""
    local COUNTER_LINES=""
    local BYPASS_COUNT=""
    local MIHOMO_RECENT_LOG=""
    local LOG_ERRORS=""
    local SERVICE_FILE=""

    health_pass() {
        echo -e "${GREEN}[PASS]${RESET} $1"
        PASS=$((PASS + 1))
    }

    health_fail() {
        echo -e "${RED}[FAIL]${RESET} $1"
        FAIL=$((FAIL + 1))
    }

    health_warn() {
        echo -e "${YELLOW}[WARN]${RESET} $1"
        WARN=$((WARN + 1))
    }

    health_info() {
        echo -e "${CYAN}[INFO]${RESET} $1"
        INFO_COUNT=$((INFO_COUNT + 1))
    }

    health_section() {
        echo
        echo "============================================================"
        echo "$1"
        echo "============================================================"
    }

    health_subsection() {
        echo
        echo "-------------------- $1 --------------------"
    }

###############################################################################
# 基础工具
###############################################################################

health_section "一、检查基础工具"

REQUIRED_TOOLS="
ip
nft
ss
curl
awk
grep
sed
systemctl
getent
sysctl
pgrep
journalctl
"

for cmd in $REQUIRED_TOOLS; do
    if command -v "$cmd" >/dev/null 2>&1; then
        health_pass "$cmd"
    else
        health_fail "缺少 $cmd"
    fi
done

###############################################################################
# 自动识别 LAN
###############################################################################

health_section "二、自动识别网络"

DEFAULT_ROUTE="$(ip -4 route show default 2>/dev/null | head -n1 || true)"

LAN_IF=""

while read -r candidate_if candidate_cidr; do
    case "$candidate_cidr" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
            LAN_IF="$candidate_if"
            break
            ;;
    esac
done < <(
    ip -o -4 addr show scope global 2>/dev/null |
    awk '$3 == "inet" {print $2, $4}' || true
)

if [ -z "$LAN_IF" ] && [ -n "$DEFAULT_ROUTE" ]; then
    LAN_IF="$(
        echo "$DEFAULT_ROUTE" |
        awk '
        {
            for (i=1; i<=NF; i++) {
                if ($i=="dev") {
                    print $(i+1)
                    exit
                }
            }
        }'
    )"
fi

if [ -n "$LAN_IF" ]; then
    health_pass "LAN 网卡：$LAN_IF"
else
    health_fail "无法自动识别默认路由网卡"
fi

###############################################################################
# LAN IPv4
###############################################################################

LAN_IP=""

if [ -n "$LAN_IF" ]; then
    LAN_IP="$(
        ip -4 -o addr show dev "$LAN_IF" 2>/dev/null |
        awk '$3=="inet" {print $4; exit}' ||
        true
    )"
fi

if [ -n "$LAN_IP" ]; then
    health_pass "LAN IPv4：$LAN_IP"
else
    health_fail "无法获取 LAN IPv4"
fi

###############################################################################
# LAN 网络
###############################################################################

LAN_CIDR=""

if [ -n "$LAN_IF" ]; then

    LAN_CIDR="$(
        ip -4 route show dev "$LAN_IF" scope link 2>/dev/null |
        awk '
        $1 ~ /^[0-9]+\./ && $1 != "default" {
            print $1
            exit
        }' ||
        true
    )"

fi

if [ -n "$LAN_CIDR" ]; then
    health_pass "LAN 网络：$LAN_CIDR"
else
    health_warn "无法自动获取 LAN 网络"
fi

###############################################################################
# 默认网关
###############################################################################

GATEWAY=""

if [ -n "$DEFAULT_ROUTE" ]; then

    GATEWAY="$(
        echo "$DEFAULT_ROUTE" |
        awk '
        {
            for (i=1; i<=NF; i++) {
                if ($i=="via") {
                    print $(i+1)
                    exit
                }
            }
        }'
    )"

fi

if [ -n "$GATEWAY" ]; then
    health_pass "默认网关：$GATEWAY"
else
    health_warn "没有检测到默认网关"
fi

###############################################################################
# 默认路由
###############################################################################

echo
echo "默认路由："

if [ -n "$DEFAULT_ROUTE" ]; then
    echo "$DEFAULT_ROUTE"
else
    health_fail "没有 IPv4 默认路由"
fi

DEFAULT_COUNT="$(ip -4 route show default 2>/dev/null | wc -l)"

if [ "$DEFAULT_COUNT" -eq 1 ]; then
    health_pass "默认路由数量：1"
elif [ "$DEFAULT_COUNT" -gt 1 ]; then
    health_warn "默认路由数量：$DEFAULT_COUNT"
else
    health_fail "没有默认路由"
fi

###############################################################################
# 网卡状态
###############################################################################

if [ -n "$LAN_IF" ]; then

    if ip link show "$LAN_IF" 2>/dev/null |
        grep -qE 'state UP|UP'
    then
        health_pass "$LAN_IF 状态：UP"
    else
        health_fail "$LAN_IF 状态异常"
    fi

fi

###############################################################################
# IPv4 Forward
###############################################################################

health_section "三、检查内核网络参数"

IP_FORWARD="$(
    sysctl -n net.ipv4.ip_forward 2>/dev/null ||
    echo 0
)"

if [ "$IP_FORWARD" = "1" ]; then
    health_pass "net.ipv4.ip_forward = 1"
else
    health_fail "net.ipv4.ip_forward = $IP_FORWARD"
fi

###############################################################################
# rp_filter
###############################################################################

RP_ALL="$(
    sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null ||
    echo 0
)"

RP_DEFAULT="$(
    sysctl -n net.ipv4.conf.default.rp_filter 2>/dev/null ||
    echo 0
)"

echo "all.rp_filter     = $RP_ALL"
echo "default.rp_filter = $RP_DEFAULT"

RP_IF="0"

if [ -n "$LAN_IF" ]; then
    RP_IF="$(
        sysctl -n "net.ipv4.conf.$LAN_IF.rp_filter" 2>/dev/null ||
        echo 0
    )"

    echo "$LAN_IF.rp_filter = $RP_IF"
fi

if [ "$RP_ALL" = "0" ] && [ "$RP_IF" = "0" ]; then
    health_pass "LAN TProxy 入口 rp_filter = 0"
else
    health_warn "LAN TProxy 入口 rp_filter 不是 0"
fi

if [ "$RP_DEFAULT" != "0" ]; then
    health_warn "default.rp_filter = $RP_DEFAULT"
else
    health_pass "default.rp_filter = 0"
fi

###############################################################################
# src_valid_mark
###############################################################################

SRC_VALID_MARK="$(
    sysctl -n net.ipv4.conf.all.src_valid_mark 2>/dev/null ||
    echo 0
)"

echo "all.src_valid_mark = $SRC_VALID_MARK"

if [ "$SRC_VALID_MARK" = "1" ]; then
    health_pass "all.src_valid_mark = 1"
else
    health_info "all.src_valid_mark = 0（当前 TProxy 实际路由测试正常，无需强制开启）"
fi

###############################################################################
# route_localnet
###############################################################################

ROUTE_LOCALNET=""

if [ -n "$LAN_IF" ]; then

    ROUTE_LOCALNET="$(
        sysctl -n "net.ipv4.conf.$LAN_IF.route_localnet" 2>/dev/null ||
        echo 0
    )"

    echo "$LAN_IF.route_localnet = $ROUTE_LOCALNET"

    if [ "$ROUTE_LOCALNET" = "1" ]; then
        health_pass "$LAN_IF route_localnet = 1"
    else
        health_info "$LAN_IF route_localnet = $ROUTE_LOCALNET"
    fi

fi

###############################################################################
# TProxy 内核模块
###############################################################################

health_section "四、检查 TProxy 内核能力"

if [ -d /sys/module/nft_tproxy ]; then
    health_pass "nft_tproxy 内核模块已加载"
else
    health_warn "nft_tproxy 模块没有出现在 /sys/module"
fi

if [ -d /sys/module/nf_tproxy_ipv4 ]; then
    health_pass "nf_tproxy_ipv4 模块已加载"
else
    health_info "nf_tproxy_ipv4 模块未单独显示"
fi

###############################################################################
# Policy Routing 自动发现
###############################################################################

health_section "五、检查 Policy Routing"

echo "========== ip -4 rule =========="

ip -4 rule

POLICY_LINE="$(
    ip -4 rule 2>/dev/null |
    grep -E 'fwmark [^ ]+.*lookup [0-9]+' |
    grep -v 'lookup main' |
    head -n1 ||
    true
)"

MARK=""
TABLE=""

if [ -n "$POLICY_LINE" ]; then

    MARK="$(
        echo "$POLICY_LINE" |
        sed -nE 's/.*fwmark ([^ ]+).*/\1/p'
    )"

    TABLE="$(
        echo "$POLICY_LINE" |
        sed -nE 's/.*lookup ([0-9]+).*/\1/p'
    )"

fi

if [ -n "$MARK" ] && [ -n "$TABLE" ]; then

    health_pass "Policy Routing：fwmark $MARK → table $TABLE"

else

    health_fail "没有找到 fwmark → policy table"

fi

###############################################################################
# Policy Table
###############################################################################

if [ -n "$TABLE" ]; then

    health_subsection "路由表 $TABLE"

    TABLE_ROUTE="$(
        ip -4 route show table "$TABLE" 2>/dev/null ||
        true
    )"

    if [ -n "$TABLE_ROUTE" ]; then

        echo "$TABLE_ROUTE"

        if echo "$TABLE_ROUTE" |
            grep -qE '^local default'
        then

            health_pass "table $TABLE 存在 local default"

        else

            health_warn "table $TABLE 没有 local default"

        fi

    else

        health_fail "table $TABLE 为空"

    fi

fi

###############################################################################
# Mark Route Test
###############################################################################

health_section "六、检查 fwmark 路由"

TEST_IP=""

TEST_IP="$(
    getent ahostsv4 "$DNS_TEST_DOMAIN" 2>/dev/null |
    awk '
    $1 !~ /^127\./ &&
    $1 !~ /^10\./ &&
    $1 !~ /^192\.168\./ &&
    $1 !~ /^172\.(1[6-9]|2[0-9]|3[0-1])\./ {
        print $1
        exit
    }' ||
    true
)"

if [ -z "$TEST_IP" ]; then
    TEST_IP="1.1.1.1"
fi

health_info "Mark 路由测试目标：$TEST_IP"

if [ -n "$MARK" ]; then

    MARK_ROUTE="$(
        ip -4 route get "$TEST_IP" mark "$MARK" 2>/dev/null ||
        true
    )"

    echo "$MARK_ROUTE"

    if echo "$MARK_ROUTE" |
        grep -qE 'local .*dev lo'
    then

        health_pass "fwmark $MARK → lo"

    else

        health_fail "fwmark $MARK 没有正确进入 lo"

    fi

else

    health_warn "无法测试 fwmark 路由"

fi

###############################################################################
# nftables 自动发现
###############################################################################

health_section "七、检查 nftables"

NFT_TABLES="$(
    nft list tables 2>/dev/null ||
    true
)"

NFT_FAMILY=""
NFT_TABLE=""

while read -r _ FAMILY TABLE_NAME; do

    [ -z "$TABLE_NAME" ] && continue

    if echo "$TABLE_NAME" |
        grep -qi "mihomo"
    then

        NFT_FAMILY="$FAMILY"
        NFT_TABLE="$TABLE_NAME"
        break

    fi

done <<< "$NFT_TABLES"

if [ -n "$NFT_FAMILY" ] && [ -n "$NFT_TABLE" ]; then

    health_pass "发现 Mihomo nft 表：$NFT_FAMILY $NFT_TABLE"

else

    health_fail "没有发现 Mihomo nft 表"

fi

###############################################################################
# 读取 nft
###############################################################################

NFT_RULES=""

if [ -n "$NFT_FAMILY" ] && [ -n "$NFT_TABLE" ]; then

    NFT_RULES="$(
        nft list table "$NFT_FAMILY" "$NFT_TABLE" 2>/dev/null ||
        true
    )"

fi

if [ -z "$NFT_RULES" ]; then
    health_fail "无法读取 Mihomo nft 规则"
else
    echo "$NFT_RULES"
fi

###############################################################################
# 自动识别 TProxy 端口
###############################################################################

TPROXY_PORT=""

if [ -n "$NFT_RULES" ]; then

    TPROXY_PORT="$(
        echo "$NFT_RULES" |
        sed -nE 's/.*tproxy to :([0-9]+).*/\1/p' |
        head -n1
    )"

fi

if [ -z "$TPROXY_PORT" ]; then

    TPROXY_PORT="$DEFAULT_TPROXY_PORT"

    health_warn "无法从 nft 自动识别 TProxy 端口，使用兜底：$TPROXY_PORT"

else

    health_pass "TProxy 端口：$TPROXY_PORT"

fi

###############################################################################
# nft chain
###############################################################################

if [ -n "$NFT_RULES" ]; then

    if echo "$NFT_RULES" |
        grep -qE 'chain[[:space:]]+prerouting'
    then
        health_pass "存在 prerouting chain"
    else
        health_fail "不存在 prerouting chain"
    fi

    if echo "$NFT_RULES" |
        grep -qE 'chain[[:space:]]+output'
    then
        health_pass "存在 output chain"
    else
        health_fail "不存在 output chain"
    fi

    if echo "$NFT_RULES" |
        grep -q "tproxy to :$TPROXY_PORT"
    then
        health_pass "存在 TProxy → :$TPROXY_PORT"
    else
        health_fail "不存在 TProxy → :$TPROXY_PORT"
    fi

    if echo "$NFT_RULES" |
        grep -Eq 'meta mark set'
    then
        health_pass "存在 nft mark 设置"
    else
        health_fail "没有发现 meta mark set"
    fi

fi

###############################################################################
# LAN CIDR
###############################################################################

if [ -n "$LAN_CIDR" ] && [ -n "$NFT_RULES" ]; then

    if echo "$NFT_RULES" |
        grep -Fq "$LAN_CIDR"
    then
        health_pass "nft 发现 LAN 网络：$LAN_CIDR"
    else
        health_warn "nft 没有直接出现 LAN 网络：$LAN_CIDR"
    fi

fi

###############################################################################
# 检查 PREROUTING TProxy
###############################################################################

health_section "八、检查 LAN → TProxy"

if [ -n "$NFT_RULES" ]; then

    PREROUTING_BLOCK="$(
        echo "$NFT_RULES" |
        sed -n '/chain prerouting/,/^[[:space:]]*}/p'
    )"

    if [ -n "$PREROUTING_BLOCK" ]; then
        echo "$PREROUTING_BLOCK"
    fi

    if echo "$PREROUTING_BLOCK" |
        grep -q "tproxy to :$TPROXY_PORT"
    then
        health_pass "PREROUTING 存在 TProxy"
    else
        health_fail "PREROUTING 没有 TProxy"
    fi

    if echo "$PREROUTING_BLOCK" |
        grep -qE 'meta mark set'
    then
        health_pass "PREROUTING 存在 mark"
    else
        health_warn "PREROUTING 没有明显 mark 设置"
    fi

fi

###############################################################################
# 检查 OUTPUT TProxy
###############################################################################

health_section "九、检查本机 OUTPUT → Policy Routing → TProxy"

NFT_OUTPUT=""
if [ -n "$NFT_FAMILY" ] && [ -n "$NFT_TABLE" ]; then
    NFT_OUTPUT="$(nft list chain "$NFT_FAMILY" "$NFT_TABLE" output 2>/dev/null || true)"
fi

if [ -z "$NFT_OUTPUT" ]; then
    health_fail "无法读取 Mihomo output chain"
else
    echo "$NFT_OUTPUT"

    ###########################################################################
    # TCP / UDP OUTPUT mark
    ###########################################################################

    if echo "$NFT_OUTPUT" | grep -Eq \
        'meta l4proto tcp.*meta mark set|meta l4proto udp.*meta mark set'; then

        health_pass "OUTPUT 存在 TCP/UDP mark"

    else

        health_fail "OUTPUT 没有发现 TCP/UDP mark"

    fi

    ###########################################################################
    # OUTPUT → fwmark → Policy Routing → table 100 → lo
    #
    # 注意：
    # OUTPUT 链本身不需要出现 tproxy to :7893。
    #
    # 正确结构是：
    #
    # OUTPUT
    #   ↓
    # meta mark set 0x1
    #   ↓
    # ip rule fwmark 0x1 lookup 100
    #   ↓
    # table 100
    #   ↓
    # local default dev lo
    #   ↓
    # Mihomo TProxy
    ###########################################################################

    OUTPUT_MARK_ROUTE="$(
        ip -4 route get 8.8.8.8 mark "$MARK" 2>/dev/null || true
    )"

    echo
    echo "OUTPUT mark 路由测试："
    echo "$OUTPUT_MARK_ROUTE"

    if echo "$OUTPUT_MARK_ROUTE" | grep -Eq \
        'local .* dev lo .*mark 1|local .* dev lo .*mark 0x1'; then

        health_pass "OUTPUT → fwmark $MARK → table $TABLE → lo"

    else

        health_fail "OUTPUT → fwmark $MARK → table $TABLE → lo 链路异常"

    fi
fi

###############################################################################
# Mihomo Service
###############################################################################

health_section "十、检查 Mihomo 服务"

if systemctl is-active --quiet "$HEALTH_SERVICE"; then
    health_pass "Mihomo：active"
else
    health_fail "Mihomo：inactive"
fi

if systemctl is-enabled --quiet "$HEALTH_SERVICE" 2>/dev/null; then
    health_pass "Mihomo：enabled"
else
    health_warn "Mihomo 没有 enabled"
fi

###############################################################################
# Mihomo Process
###############################################################################

MIHOMO_PID="$(
    pgrep -x mihomo |
    head -n1 ||
    true
)"

if [ -n "$MIHOMO_PID" ]; then
    health_pass "Mihomo PID：$MIHOMO_PID"
else
    health_fail "没有 Mihomo 进程"
fi

###############################################################################
# Mihomo User
###############################################################################

health_section "十一、检查 Mihomo 用户"

if id "$MIHOMO_USER" >/dev/null 2>&1; then

    MIHOMO_UID="$(id -u "$MIHOMO_USER")"

    health_pass "用户存在：$MIHOMO_USER"
    health_info "UID：$MIHOMO_UID"

else

    health_warn "用户不存在：$MIHOMO_USER"

fi

###############################################################################
# 配置文件自动发现
###############################################################################

health_section "十二、检查 Mihomo 配置"

CONFIG_FILE=""

for f in \
    "$MIHOMO_DIR/config.yaml" \
    "$MIHOMO_DIR/config.yml" \
    "/etc/mihomo/config.yaml" \
    "/etc/mihomo/config.yml"
do

    if [ -f "$f" ]; then
        CONFIG_FILE="$f"
        break
    fi

done

if [ -n "$CONFIG_FILE" ]; then

    health_pass "配置文件：$CONFIG_FILE"

else

    health_warn "没有找到标准 Mihomo 配置文件"

fi

###############################################################################
# 从配置读取 Controller
###############################################################################

API_PORT="$DEFAULT_API_PORT"

if [ -n "$CONFIG_FILE" ]; then

    CONFIG_API="$(
        grep -E '^[[:space:]]*external-controller:' "$CONFIG_FILE" 2>/dev/null |
        head -n1 |
        sed -nE 's/.*:([0-9]+)[[:space:]]*$/\1/p'
    )"

    if [ -n "$CONFIG_API" ]; then
        API_PORT="$CONFIG_API"
    fi

fi

health_info "Controller：$API_PORT"

###############################################################################
# Mihomo 监听端口
###############################################################################

health_section "十三、检查 Mihomo Socket"

echo "========== TCP =========="

ss -lntp 2>/dev/null |
    grep -E 'mihomo|:53\b|:789[0-9]\b|:9090\b' ||
    true

echo
echo "========== UDP =========="

ss -lunp 2>/dev/null |
    grep -E 'mihomo|:53\b|:789[0-9]\b|:9090\b' ||
    true

###############################################################################
# DNS
###############################################################################

health_section "十四、检查 Mihomo DNS"

if ss -lunp 2>/dev/null |
    grep -Eq '([.:])53\b'
then
    health_pass "UDP :53 正在监听"
else
    health_fail "UDP :53 没有监听"
fi

if ss -lunp 2>/dev/null |
    grep -E '([.:])53\b' |
    grep -qi mihomo
then
    health_pass "UDP :53 由 Mihomo 监听"
else
    health_fail "UDP :53 不是 Mihomo"
fi

if ss -lntp 2>/dev/null |
    grep -E '([.:])53\b' |
    grep -qi mihomo
then
    health_pass "TCP :53 由 Mihomo 监听"
else
    health_warn "TCP :53 不是 Mihomo"
fi

###############################################################################
# resolv.conf
###############################################################################

health_section "十五、检查系统 DNS"

if [ -f /etc/resolv.conf ]; then

    cat /etc/resolv.conf

    if grep -Eq \
        '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1([[:space:]]|$)' \
        /etc/resolv.conf
    then

        health_pass "系统 DNS → 127.0.0.1"

    else

        health_warn "系统 DNS 没有指向 127.0.0.1"

    fi

else

    health_warn "/etc/resolv.conf 不存在"

fi

###############################################################################
# DNS 实际测试
###############################################################################

health_section "十六、实际 DNS 测试"

DNS_RESULT="$(
    env -u HTTP_PROXY \
        -u HTTPS_PROXY \
        -u ALL_PROXY \
        -u http_proxy \
        -u https_proxy \
        -u all_proxy \
        getent ahostsv4 "$DNS_TEST_DOMAIN" 2>/dev/null |
    awk '{print $1}' |
    sort -u |
    head -n5 ||
    true
)"

if [ -n "$DNS_RESULT" ]; then

    echo "$DNS_RESULT"
    health_pass "DNS 解析正常：$DNS_TEST_DOMAIN"

else

    health_fail "DNS 解析失败：$DNS_TEST_DOMAIN"

fi

###############################################################################
# TProxy UDP
###############################################################################

health_section "十七、检查 TProxy Socket"

if ss -lunp 2>/dev/null |
    grep -Eq "([.:])$TPROXY_PORT\b"
then

    health_pass "UDP :$TPROXY_PORT 正在监听"

else

    health_fail "UDP :$TPROXY_PORT 没有监听"

fi

if ss -lunp 2>/dev/null |
    grep -E "([.:])$TPROXY_PORT\b" |
    grep -qi mihomo
then

    health_pass "UDP :$TPROXY_PORT 属于 Mihomo"

else

    health_fail "UDP :$TPROXY_PORT 不是 Mihomo"

fi

###############################################################################
# TProxy TCP
###############################################################################

if ss -lntp 2>/dev/null |
    grep -Eq "([.:])$TPROXY_PORT\b"
then

    health_pass "TCP :$TPROXY_PORT 正在监听"

else

    health_fail "TCP :$TPROXY_PORT 没有监听"

fi

if ss -lntp 2>/dev/null |
    grep -E "([.:])$TPROXY_PORT\b" |
    grep -qi mihomo
then

    health_pass "TCP :$TPROXY_PORT 属于 Mihomo"

else

    health_fail "TCP :$TPROXY_PORT 不是 Mihomo"

fi

###############################################################################
# Controller
###############################################################################

health_section "十八、检查 Mihomo Controller"

API_CODE="$(
    env -u HTTP_PROXY \
        -u HTTPS_PROXY \
        -u ALL_PROXY \
        -u http_proxy \
        -u https_proxy \
        -u all_proxy \
        curl -s \
        -o /dev/null \
        -w "%{http_code}" \
        --connect-timeout 3 \
        --max-time 5 \
        "http://127.0.0.1:$API_PORT/" \
        2>/dev/null ||
    true
)"

[ -n "$API_CODE" ] || API_CODE="000"

echo "HTTP Code：$API_CODE"

case "$API_CODE" in
    200|204|301|302|401|403)
        health_pass "Controller :$API_PORT 可访问"
        ;;
    *)
        health_warn "Controller :$API_PORT 无法正常访问"
        ;;
esac

###############################################################################
# 本机 HTTPS
###############################################################################

health_section "十九、本机实际 HTTPS"

health_info "测试：$HTTPS_TEST_URL"

HTTP_CODE="$(
    env -u HTTP_PROXY \
        -u HTTPS_PROXY \
        -u ALL_PROXY \
        -u http_proxy \
        -u https_proxy \
        -u all_proxy \
        curl -4 \
        -L \
        -s \
        -o /dev/null \
        -w "%{http_code}" \
        --connect-timeout 10 \
        --max-time 20 \
        "$HTTPS_TEST_URL" \
        2>/dev/null ||
    true
)"

[ -n "$HTTP_CODE" ] || HTTP_CODE="000"

echo "HTTP Code：$HTTP_CODE"

case "$HTTP_CODE" in
    2*|3*)
        health_pass "本机 HTTPS 正常"
        ;;
    *)
        health_fail "本机 HTTPS 失败"
        ;;
esac

###############################################################################
# 代理环境变量
###############################################################################

health_section "二十、检查代理环境变量"

PROXY_ENV=0

for V in \
    HTTP_PROXY \
    HTTPS_PROXY \
    ALL_PROXY \
    http_proxy \
    https_proxy \
    all_proxy
do

    if [ -n "${!V:-}" ]; then

        echo "$V=${!V}"
        PROXY_ENV=1

    fi

done

if [ "$PROXY_ENV" -eq 0 ]; then
    health_pass "当前环境没有 HTTP/HTTPS/ALL_PROXY"
else
    health_warn "当前环境存在代理变量"
fi

###############################################################################
# nft Counter
###############################################################################

health_section "二十一、检查 nft Counter"

if [ -n "$NFT_RULES" ]; then

    COUNTER_LINES="$(
        echo "$NFT_RULES" |
        grep -E 'counter|tproxy|mark set' |
        head -n50 ||
        true
    )"

    if [ -n "$COUNTER_LINES" ]; then
        echo "$COUNTER_LINES"
        health_pass "发现 nft 流量统计规则"
    else
        health_warn "没有发现明显 nft counter"
    fi

else

    health_warn "无法读取 nft counter"

fi

###############################################################################
# 检查规则是否包含 bypass
###############################################################################

health_section "二十二、检查常见直连排除规则"

if [ -n "$NFT_RULES" ]; then

    BYPASS_COUNT="$(
        echo "$NFT_RULES" |
        grep -Eic \
        'return|accept|127\.0\.0\.0/8|224\.0\.0\.0/4|255\.255\.255\.255|localhost' ||
        true
    )"

    if [ "$BYPASS_COUNT" -gt 0 ]; then
        health_info "发现 $BYPASS_COUNT 个常见 bypass/return 相关规则"
    else
        health_info "没有发现明显 bypass 规则"
    fi

fi

###############################################################################
# 本机路由
###############################################################################

health_section "二十三、检查主路由表"

ip -4 route show table main

if [ -n "$LAN_IF" ]; then

    echo
    echo "LAN 路由："

    ip -4 route show dev "$LAN_IF" 2>/dev/null ||
        true

fi

###############################################################################
# 检查本机到网关
###############################################################################

health_section "二十四、检查网关连通性"

if [ -n "$GATEWAY" ]; then

    if ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
        health_pass "默认网关可达：$GATEWAY"
    else
        health_warn "默认网关 ICMP 不可达：$GATEWAY"
    fi

else

    health_info "没有网关地址，跳过"

fi

###############################################################################
# Mihomo 日志错误扫描
###############################################################################

health_section "二十五、Mihomo 日志错误扫描"

# 读取最近日志
MIHOMO_RECENT_LOG="$(
    journalctl -u "$HEALTH_SERVICE" \
        -n 10 \
        --no-pager \
        2>/dev/null || true
)"

# 初始化，避免 set -u 下变量未定义
LOG_ERRORS=""

if [ -n "$MIHOMO_RECENT_LOG" ]; then

    LOG_ERRORS="$(
        echo "$MIHOMO_RECENT_LOG" |
        grep -Ei \
        'error|failed|failure|fatal|panic|timeout|timed out|connection refused|network unreachable|no route to host|i/o timeout' \
        || true
    )"

fi

if [ -n "$LOG_ERRORS" ]; then

    echo "$LOG_ERRORS"

    # 判断是否属于网络出口类异常
    if echo "$LOG_ERRORS" | grep -Eqi \
        'i/o timeout|timeout|timed out|connection refused|network unreachable|no route to host'; then

        health_warn "Mihomo 最近存在出口连接异常，但不判定为 TProxy 核心故障"

    else

        health_warn "Mihomo 最近存在异常日志，请检查"

    fi

else

    health_pass "最近 Mihomo 日志没有发现明显错误"

fi

###############################################################################
# systemd 启动依赖
###############################################################################

health_section "二十六、检查 Mihomo systemd"

SERVICE_FILE="$(
    systemctl show "$HEALTH_SERVICE" \
        -p FragmentPath \
        --value \
        2>/dev/null ||
    true
)"

if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]; then

    health_info "Service：$SERVICE_FILE"

    if grep -qE 'After=.*network' "$SERVICE_FILE"; then
        health_pass "Mihomo service 包含网络启动依赖"
    else
        health_info "Mihomo service 未发现明显 network After"
    fi

else

    health_warn "无法获取 Mihomo service 文件"

fi

###############################################################################
# 最终诊断
###############################################################################

health_section "最终诊断"

echo
echo "自动识别结果："
echo "------------------------------------------------------------"
echo "LAN_IF       = ${LAN_IF:-未识别}"
echo "LAN_IP       = ${LAN_IP:-未识别}"
echo "LAN_CIDR     = ${LAN_CIDR:-未识别}"
echo "GATEWAY      = ${GATEWAY:-未识别}"
echo "NFT_FAMILY   = ${NFT_FAMILY:-未识别}"
echo "NFT_TABLE    = ${NFT_TABLE:-未识别}"
echo "TPROXY_PORT  = ${TPROXY_PORT:-未识别}"
echo "MARK         = ${MARK:-未识别}"
echo "TABLE        = ${TABLE:-未识别}"
echo "API_PORT     = ${API_PORT:-未识别}"
echo "------------------------------------------------------------"

echo
echo "检查统计："
echo "------------------------------------------------------------"
echo -e "${GREEN}PASS：$PASS${RESET}"
echo -e "${YELLOW}WARN：$WARN${RESET}"
echo -e "${RED}FAIL：$FAIL${RESET}"
echo "------------------------------------------------------------"


    health_section "最终状态"

    if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
        echo -e "${GREEN}透明代理健康状态：HEALTHY${RESET}"
        return 0
    elif [ "$FAIL" -eq 0 ]; then
        echo -e "${YELLOW}透明代理健康状态：DEGRADED${RESET}"
        echo -e "${YELLOW}核心链路正常，但存在 WARN 项${RESET}"
        return 0
    else
        echo -e "${RED}透明代理健康状态：FAILED${RESET}"
        echo -e "${RED}存在核心故障，请根据上面的 FAIL 项排查${RESET}"
        return 1
    fi
}

full_check() {
    health_check
}


###############################################################################
# 集成网络配置功能
###############################################################################

NETWORK_DIR="/etc/systemd/network"
NETWORK_MIHOMO_CONFIG="${MIHOMO_CONFIG}"
NETWORK_MIHOMO_SERVICE="mihomo"
ACTIVE_IF=""
NETWORK_FILE=""
NETWORK_BACKUP_FILE=""
CHECK_MODE=0
CHECK_ISSUES=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_RESET=$'\033[0m'
    COLOR_RED=$'\033[31m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_CYAN=$'\033[36m'
    COLOR_BOLD=$'\033[1m'
else
    COLOR_RESET=""
    COLOR_RED=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_CYAN=""
    COLOR_BOLD=""
fi

network_info() {
    printf '%s[INFO]%s %s\n' "$COLOR_CYAN" "$COLOR_RESET" "$*"
}

network_pass() {
    printf '%s[PASS]%s %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

network_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*"
    if [ "$CHECK_MODE" -eq 1 ]; then
        CHECK_ISSUES=$((CHECK_ISSUES + 1))
    fi
}

network_error() {
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    if [ "$CHECK_MODE" -eq 1 ]; then
        CHECK_ISSUES=$((CHECK_ISSUES + 1))
    fi
}

validate_ipv4() {

    local IP="$1"
    local A B C D
    local N

    if [[ ! "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi

    IFS='.' read -r A B C D <<< "$IP"

    for N in "$A" "$B" "$C" "$D"; do

        if (( 10#$N > 255 )); then
            return 1
        fi

    done

    return 0
}

validate_host_ipv4() {

    local IP_ADDR="$1"
    local PREFIX="$2"
    local A B C D
    local IP_INT MASK NETWORK BROADCAST

    IFS='.' read -r A B C D <<< "$IP_ADDR"

    if [ "$((10#$A))" -eq 0 ] || [ "$((10#$A))" -eq 127 ] ||
       [ "$((10#$A))" -ge 224 ] || [ "$IP_ADDR" = "255.255.255.255" ]; then
        return 1
    fi

    [ "$PREFIX" -ge 31 ] && return 0

    IP_INT=$(( (10#$A << 24) | (10#$B << 16) | (10#$C << 8) | 10#$D ))
    if [ "$PREFIX" -eq 32 ]; then
        MASK=4294967295
    else
        MASK=$((4294967295 << (32 - PREFIX)))
    fi

    NETWORK=$((IP_INT & MASK))
    BROADCAST=$((NETWORK | (4294967295 ^ MASK)))

    [ "$IP_INT" -ne "$NETWORK" ] && [ "$IP_INT" -ne "$BROADCAST" ]
}

ipv4_same_subnet() {

    local IP_ADDR="$1"
    local GATEWAY="$2"
    local PREFIX="$3"
    local IA IB IC ID
    local GA GB GC GD
    local IP_INT GW_INT MASK

    IFS='.' read -r IA IB IC ID <<< "$IP_ADDR"
    IFS='.' read -r GA GB GC GD <<< "$GATEWAY"

    IP_INT=$(( (10#$IA << 24) | (10#$IB << 16) | (10#$IC << 8) | 10#$ID ))
    GW_INT=$(( (10#$GA << 24) | (10#$GB << 16) | (10#$GC << 8) | 10#$GD ))

    if [ "$PREFIX" -eq 32 ]; then
        MASK=4294967295
    else
        MASK=$((4294967295 << (32 - PREFIX)))
    fi

    (( (IP_INT & MASK) == (GW_INT & MASK) ))
}

###############################################################################
# 自动识别物理网卡
###############################################################################

detect_interface() {

    local DEFAULT_IF=""
    local IFACE=""
    local TYPE=""
    local CARRIER=""
    local PATH_IF=""

    DEFAULT_IF="$(
        ip -4 route show default 2>/dev/null |
        awk 'NR==1 {print $5}'
    )"

    if [ -n "$DEFAULT_IF" ] &&
       [ "$DEFAULT_IF" != "lo" ] &&
       [ -d "/sys/class/net/$DEFAULT_IF" ]; then

        TYPE="$(cat "/sys/class/net/$DEFAULT_IF/type" 2>/dev/null || echo 0)"

        if [ "$TYPE" = "1" ]; then
            echo "$DEFAULT_IF"
            return 0
        fi

    fi

    for PATH_IF in /sys/class/net/*; do

        IFACE="$(basename "$PATH_IF")"

        [ "$IFACE" = "lo" ] && continue
        [ -f "$PATH_IF/type" ] || continue

        TYPE="$(cat "$PATH_IF/type" 2>/dev/null || echo 0)"

        [ "$TYPE" = "1" ] || continue

        if [ -f "$PATH_IF/carrier" ]; then

            CARRIER="$(cat "$PATH_IF/carrier" 2>/dev/null || echo 0)"

            if [ "$CARRIER" = "1" ]; then
                echo "$IFACE"
                return 0
            fi

        fi

    done

    return 1
}

###############################################################################
# NetworkManager 状态
#
# 注意：
#
# 不删除当前连接。
# 不执行：
#
#   nmcli connection delete
#
# 因为这可能立即导致：
#
#   IP 消失
#   默认路由消失
#   SSH 断开
#
###############################################################################

check_nm() {

    local IFACE="$1"
    local NM_STATE=""

    echo
    echo "【NetworkManager】"

    if ! command -v nmcli >/dev/null 2>&1; then
        network_info "nmcli 不存在。"
        return 0
    fi

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then

        echo "NetworkManager：active"

    else

        echo "NetworkManager：inactive"
        return 0

    fi

    NM_STATE="$(
        nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null |
        awk -F: -v IFACE="$IFACE" '$1 == IFACE {print $3}'
    )"

    case "$NM_STATE" in

        "connected (externally)")
            network_pass "NetworkManager 未主动建立 $IFACE 连接。"
            ;;

        "connected")
            network_warn "NetworkManager 正在主动管理 $IFACE。"
            network_warn "本脚本不会删除当前连接。"
            ;;

        "")
            network_info "NetworkManager 未接管 $IFACE。"
            ;;

        *)
            echo "NM $IFACE：$NM_STATE"
            ;;

    esac
}

###############################################################################
# 自动识别网卡的 IP 管理方式
###############################################################################

get_nm_connection() {

    local IFACE="$1"
    local NM_STATE=""
    local NM_UUID=""

    command -v nmcli >/dev/null 2>&1 || return 1
    systemctl is-active --quiet NetworkManager 2>/dev/null || return 1

    NM_STATE="$(nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null || true)"

    if [[ "$NM_STATE" =~ ^100[[:space:]]+\(connected\)$ ]]; then
        NM_UUID="$(nmcli -g GENERAL.UUID device show "$IFACE" 2>/dev/null || true)"
    elif [[ "$NM_STATE" =~ ^30[[:space:]]+\(disconnected\)$ ]]; then
        # disconnected 时没有活动 UUID，从绑定到该接口的连接配置中查找。
        NM_UUID="$(
            nmcli -t -f UUID,connection.interface-name connection show 2>/dev/null |
            awk -F: -v IFACE="$IFACE" '$2 == IFACE {print $1; exit}'
        )"
    else
        return 1
    fi

    [ -n "$NM_UUID" ] || return 1
    [ "$NM_UUID" != "--" ] || return 1

    printf '%s\n' "$NM_UUID"
}

nm_manages_interface() {

    local IFACE="$1"
    local NM_MANAGED=""
    local NM_STATE=""

    command -v nmcli >/dev/null 2>&1 || return 1
    systemctl is-active --quiet NetworkManager 2>/dev/null || return 1

    NM_MANAGED="$(nmcli -g GENERAL.NM-MANAGED device show "$IFACE" 2>/dev/null || true)"
    NM_STATE="$(nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null || true)"

    [ "$NM_MANAGED" = "yes" ] || return 1
    [[ "$NM_STATE" != 10\ \(unmanaged\) ]] || return 1
    [[ "$NM_STATE" != 20\ \(unavailable\) ]] || return 1
}

networkd_manages_interface() {

    local IFACE="$1"
    local NETWORK_STATUS=""
    local NETWORK_FILE=""

    systemctl is-active --quiet systemd-networkd 2>/dev/null || return 1

    if networkctl is-configured "$IFACE" >/dev/null 2>&1; then
        return 0
    fi

    NETWORK_STATUS="$(networkctl status "$IFACE" --no-pager 2>/dev/null || true)"

    if printf '%s\n' "$NETWORK_STATUS" |
       grep -Eq 'Network File:.*\.network|Managed:[[:space:]]+yes'; then
        return 0
    fi

    # 某些较旧版本的 networkctl 不显示 Network File/Managed 字段，
    # 但可以从实际的 .network 文件中判断是否匹配该网卡。
    for NETWORK_FILE in "$NETWORK_DIR"/*.network; do
        [ -f "$NETWORK_FILE" ] || continue

        if awk -v IFACE="$IFACE" '
            /^[[:space:]]*\[Match\]/ { in_match=1; next }
            /^\[/ { in_match=0 }
            in_match && $0 ~ "^[[:space:]]*Name=" IFACE "([[:space:]]|$)" { found=1 }
            END { exit(found ? 0 : 1) }
        ' "$NETWORK_FILE"; then
            return 0
        fi
    done

    return 1
}

ifupdown_config_file() {

    local IFACE="$1"
    local FILE=""

    for FILE in /etc/network/interfaces /etc/network/interfaces.d/*; do
        [ -f "$FILE" ] || continue

        if awk -v IFACE="$IFACE" '
            /^[[:space:]]*iface[[:space:]]+/ {
                if ($2 == IFACE && $3 == "inet") found=1
            }
            END { exit(found ? 0 : 1) }
        ' "$FILE"; then
            printf '%s\n' "$FILE"
            return 0
        fi
    done

    return 1
}

ifupdown_manages_interface() {

    local IFACE="$1"

    command -v ifup >/dev/null 2>&1 || return 1
    command -v ifdown >/dev/null 2>&1 || return 1
    systemctl is-active --quiet networking 2>/dev/null || return 1

    ifupdown_config_file "$IFACE" >/dev/null
}

detect_ip_manager() {

    local IFACE="$1"

    if nm_manages_interface "$IFACE"; then
        echo "NetworkManager"
        return 0
    fi

    if networkd_manages_interface "$IFACE"; then
        echo "systemd-networkd"
        return 0
    fi

    if ifupdown_manages_interface "$IFACE"; then
        echo "ifupdown"
        return 0
    fi

    return 1
}

###############################################################################
# 写入 networkd 配置
###############################################################################

write_network_config() {

    local IFACE="$1"
    local IP_ADDR="$2"
    local PREFIX="$3"
    local GATEWAY="$4"

    mkdir -p "$NETWORK_DIR"

    NETWORK_FILE="$NETWORK_DIR/10-${IFACE}.network"
    NETWORK_BACKUP_FILE=""

    if [ -f "$NETWORK_FILE" ]; then

        local BACKUP_FILE

        BACKUP_FILE="${NETWORK_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

        cp -a "$NETWORK_FILE" "$BACKUP_FILE"
        NETWORK_BACKUP_FILE="$BACKUP_FILE"

        network_pass "旧配置已备份：$BACKUP_FILE"

    fi

    local TEMP_FILE
    TEMP_FILE="$(mktemp "$NETWORK_DIR/.10-${IFACE}.network.XXXXXX")"

    cat > "$TEMP_FILE" <<EOF
[Match]
Name=$IFACE

[Network]
DHCP=no
Address=$IP_ADDR/$PREFIX
Gateway=$GATEWAY
IPv6AcceptRA=no
LinkLocalAddressing=no
IPv6SendRA=no
EOF

    chmod 644 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$NETWORK_FILE"

    network_pass "已写入：$NETWORK_FILE"
}

###############################################################################
# 应用 networkd
#
# 不重启 systemd-networkd。
###############################################################################

apply_networkd() {

    local IFACE="$1"

    echo
    network_info "重新加载 systemd-networkd 配置……"

    if ! systemctl is-active --quiet systemd-networkd; then
        network_error "systemd-networkd 未运行，未应用配置。"
        return 1
    fi

    if ! networkctl reload; then
        network_error "networkctl reload 失败。"
        return 1
    fi

    sleep 1

    network_info "重新配置 $IFACE……"

    if ! networkctl reconfigure "$IFACE"; then
        network_error "$IFACE reconfigure 失败。"
        return 1
    fi

    sleep 3

    if systemctl is-active --quiet systemd-networkd; then
        network_pass "systemd-networkd 正常运行。"
    else
        network_error "systemd-networkd 未正常运行。"
        return 1
    fi

    if networkctl is-configured "$IFACE" >/dev/null 2>&1; then
        network_pass "$IFACE 已由 systemd-networkd 配置。"
    else
        network_warn "$IFACE 尚未进入 configured 状态。"
    fi
}

restore_network_config() {

    local IFACE="$1"

    if [ -n "$NETWORK_BACKUP_FILE" ] && [ -f "$NETWORK_BACKUP_FILE" ]; then
        cp -a "$NETWORK_BACKUP_FILE" "$NETWORK_FILE"
        network_pass "已恢复旧 networkd 配置。"
    else
        rm -f "$NETWORK_FILE"
        network_pass "已移除未生效的 networkd 配置。"
    fi

    networkctl reload >/dev/null 2>&1 || true
    networkctl reconfigure "$IFACE" >/dev/null 2>&1 || true
}

configure_ip_nm() {

    local IFACE="$1"
    local IP_ADDR="$2"
    local PREFIX="$3"
    local GATEWAY="$4"
    local CONNECTION=""
    local OLD_METHOD=""
    local OLD_ADDRESSES=""
    local OLD_GATEWAY=""
    local OLD_NEVER_DEFAULT=""

    restore_nm_connection() {
        local RESTORE_CONNECTION="$1"
        local RESTORE_METHOD="$2"
        local RESTORE_ADDRESSES="$3"
        local RESTORE_GATEWAY="$4"
        local RESTORE_NEVER_DEFAULT="$5"

        [ -n "$RESTORE_METHOD" ] || return 1

        nmcli connection modify "$RESTORE_CONNECTION" \
            ipv4.method "$RESTORE_METHOD" \
            ipv4.addresses "$RESTORE_ADDRESSES" \
            ipv4.gateway "$RESTORE_GATEWAY" \
            ipv4.never-default "$RESTORE_NEVER_DEFAULT" >/dev/null 2>&1 || return 1

        nmcli connection up "$RESTORE_CONNECTION" ifname "$IFACE" \
            >/dev/null 2>&1 || return 1
    }

    CONNECTION="$(get_nm_connection "$IFACE")" || {
        network_error "无法找到 $IFACE 的 NetworkManager 活动连接。"
        return 1
    }

    network_info "使用 NetworkManager 连接：$CONNECTION"

    OLD_METHOD="$(nmcli -g ipv4.method connection show "$CONNECTION" 2>/dev/null || true)"
    OLD_ADDRESSES="$(nmcli -g ipv4.addresses connection show "$CONNECTION" 2>/dev/null || true)"
    OLD_GATEWAY="$(nmcli -g ipv4.gateway connection show "$CONNECTION" 2>/dev/null || true)"
    OLD_NEVER_DEFAULT="$(nmcli -g ipv4.never-default connection show "$CONNECTION" 2>/dev/null || true)"

    [ "$OLD_ADDRESSES" = "--" ] && OLD_ADDRESSES=""
    [ "$OLD_GATEWAY" = "--" ] && OLD_GATEWAY=""
    [ "$OLD_NEVER_DEFAULT" = "--" ] && OLD_NEVER_DEFAULT="no"

    if ! nmcli connection modify "$CONNECTION" \
        ipv4.method manual \
        ipv4.addresses "$IP_ADDR/$PREFIX" \
        ipv4.gateway "$GATEWAY" \
        ipv4.never-default no; then
        network_error "NetworkManager 配置修改失败。"
        return 1
    fi

    if ! nmcli connection up "$CONNECTION" ifname "$IFACE"; then
        network_error "NetworkManager 重新激活连接失败。"
        if restore_nm_connection "$CONNECTION" "$OLD_METHOD" "$OLD_ADDRESSES" \
            "$OLD_GATEWAY" "$OLD_NEVER_DEFAULT"; then
            network_pass "已恢复 NetworkManager 原配置。"
        else
            network_error "NetworkManager 原配置恢复失败，请手动检查连接配置。"
        fi
        return 1
    fi

    sleep 2

    if verify_ip_configuration "$IFACE" "$IP_ADDR" "$PREFIX" "$GATEWAY" &&
       remove_extra_ipv4 "$IFACE" "$IP_ADDR/$PREFIX" &&
       verify_single_ipv4 "$IFACE" "$IP_ADDR/$PREFIX"; then
        network_pass "NetworkManager 已应用 $IP_ADDR/$PREFIX。"
    else
        if restore_nm_connection "$CONNECTION" "$OLD_METHOD" "$OLD_ADDRESSES" \
            "$OLD_GATEWAY" "$OLD_NEVER_DEFAULT"; then
            network_pass "已恢复 NetworkManager 原配置。"
        else
            network_error "NetworkManager 原配置恢复失败，请手动检查连接配置。"
        fi
        return 1
    fi
}

prefix_to_netmask() {

    local PREFIX="$1"
    local MASK
    local A B C D

    if [ "$PREFIX" -eq 0 ]; then
        printf '0.0.0.0\n'
        return 0
    fi

    if [ "$PREFIX" -eq 32 ]; then
        printf '255.255.255.255\n'
        return 0
    fi

    MASK=$((4294967295 << (32 - PREFIX)))
    A=$(( (MASK >> 24) & 255 ))
    B=$(( (MASK >> 16) & 255 ))
    C=$(( (MASK >> 8) & 255 ))
    D=$(( MASK & 255 ))

    printf '%s.%s.%s.%s\n' "$A" "$B" "$C" "$D"
}

configure_ip_ifupdown() {

    local IFACE="$1"
    local IP_ADDR="$2"
    local PREFIX="$3"
    local GATEWAY="$4"
    local FILE=""
    local BACKUP=""
    local TEMP_FILE=""
    local NETMASK=""

    FILE="$(ifupdown_config_file "$IFACE" || true)"
    [ -n "$FILE" ] || {
        network_error "找不到 $IFACE 的 ifupdown 配置文件。"
        return 1
    }

    NETMASK="$(prefix_to_netmask "$PREFIX")"
    BACKUP="${FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$FILE" "$BACKUP"
    network_pass "旧 ifupdown 配置已备份：$BACKUP"

    TEMP_FILE="$(mktemp "${FILE}.XXXXXX")"

    awk \
        -v IFACE="$IFACE" \
        -v IP_ADDR="$IP_ADDR" \
        -v NETMASK="$NETMASK" \
        -v GATEWAY="$GATEWAY" '
        BEGIN { skip=0; replaced=0 }

        /^[[:space:]]*iface[[:space:]]+/ {
            if ($2 == IFACE && $3 == "inet") {
                if (!replaced) {
                    print "iface " IFACE " inet static"
                    print "    address " IP_ADDR
                    print "    netmask " NETMASK
                    print "    gateway " GATEWAY
                    replaced=1
                }
                skip=1
                next
            }

            skip=0
        }

        skip && /^[[:space:]]/ { next }
        skip { skip=0 }
        { print }

        END {
            if (!replaced) {
                print ""
                print "auto " IFACE
                print "iface " IFACE " inet static"
                print "    address " IP_ADDR
                print "    netmask " NETMASK
                print "    gateway " GATEWAY
            }
        }
    ' "$FILE" > "$TEMP_FILE"

    chmod 644 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$FILE"
    network_pass "已写入 ifupdown 配置：$FILE"

    release_dhcp_lease "$IFACE"

    if ! ifdown --force "$IFACE" >/dev/null 2>&1; then
        network_warn "$IFACE 当前未处于 ifupdown active 状态，继续执行 ifup。"
    fi

    # ifdown 在状态文件不同步、旧 DHCP 客户端残留等情况下，可能不会
    # 删除原 IPv4 地址。先清理全局 IPv4，避免新旧地址同时存在。
    if ! ip -4 addr flush dev "$IFACE" scope global; then
        network_error "无法清理 $IFACE 的旧 IPv4 地址。"
        cp -a "$BACKUP" "$FILE"
        ifup "$IFACE" >/dev/null 2>&1 || true
        return 1
    fi

    if ! ifup "$IFACE"; then
        network_error "ifupdown 启用 $IFACE 失败，正在恢复旧配置。"
        ip -4 addr flush dev "$IFACE" scope global >/dev/null 2>&1 || true
        cp -a "$BACKUP" "$FILE"
        ifup "$IFACE" >/dev/null 2>&1 || true
        return 1
    fi

    sleep 2

    if verify_ip_configuration "$IFACE" "$IP_ADDR" "$PREFIX" "$GATEWAY" &&
       verify_single_ipv4 "$IFACE" "$IP_ADDR/$PREFIX"; then
        network_pass "ifupdown 已应用 $IP_ADDR/$PREFIX。"
    else
        network_error "ifupdown 应用结果验证失败，正在恢复旧配置。"
        ifdown --force "$IFACE" >/dev/null 2>&1 || true
        ip -4 addr flush dev "$IFACE" scope global >/dev/null 2>&1 || true
        cp -a "$BACKUP" "$FILE"
        ifup "$IFACE" >/dev/null 2>&1 || true
        return 1
    fi
}

release_dhcp_lease() {

    local IFACE="$1"
    local PID_FILE=""

    # ifdown 通常会释放 DHCP，但在 ifupdown 状态文件不同步时，旧的
    # dhclient 可能继续运行并重新添加动态地址，因此这里主动释放一次。
    if command -v dhclient >/dev/null 2>&1; then
        for PID_FILE in \
            "/run/dhclient.${IFACE}.pid" \
            "/var/run/dhclient.${IFACE}.pid"; do
            if [ -f "$PID_FILE" ]; then
                dhclient -r -pf "$PID_FILE" "$IFACE" >/dev/null 2>&1 || true
            fi
        done

        dhclient -r "$IFACE" >/dev/null 2>&1 || true
    fi

    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd -k "$IFACE" >/dev/null 2>&1 || true
    fi
}

###############################################################################
# 修改 IP
###############################################################################

configure_ip() {

    local IFACE="$1"

    local IP_ADDR=""
    local PREFIX=""
    local GATEWAY=""
    local CURRENT_GATEWAY=""
    local IP_MANAGER=""
    local DEFAULT_ROUTE_COUNT=""

    IP_MANAGER="$(detect_ip_manager "$IFACE" || true)"

    if [ -z "$IP_MANAGER" ]; then
        network_error "无法识别 $IFACE 的 IP 管理方式。"
        network_warn "请确认 NetworkManager、systemd-networkd 或 ifupdown 正在管理该网卡。"
        return 1
    fi

    network_info "检测到 $IFACE 的 IP 管理方式：$IP_MANAGER"

    echo
    echo "============================================================"
    echo "                         修改 IP"
    echo "============================================================"
    echo

    while true; do

        read -r -p "请输入本机 IP，例如 192.168.50.2： " IP_ADDR

        if validate_ipv4 "$IP_ADDR"; then
            break
        fi

        network_error "IP 地址格式错误，请重新输入。"

    done

    while true; do

        read -r -p "请输入子网前缀长度 [默认 24]： " PREFIX

        PREFIX="${PREFIX:-24}"

        if [[ "$PREFIX" =~ ^[0-9]+$ ]] &&
           [ "$PREFIX" -ge 1 ] &&
           [ "$PREFIX" -le 32 ]; then
            break
        fi

        network_error "前缀长度必须是 1-32。"

    done

    if ! validate_host_ipv4 "$IP_ADDR" "$PREFIX"; then
        network_error "IP 不能是回环、组播、未指定、网络地址或广播地址：$IP_ADDR/$PREFIX"
        return 1
    fi

    CURRENT_GATEWAY="$(
        ip -4 route show default dev "$IFACE" 2>/dev/null |
        awk 'NR==1 {print $3}'
    )"

    if validate_ipv4 "$CURRENT_GATEWAY"; then

        read -r -p "请输入网关 [默认 $CURRENT_GATEWAY]： " GATEWAY

        GATEWAY="${GATEWAY:-$CURRENT_GATEWAY}"

    else

        while true; do

            read -r -p "请输入网关，例如 192.168.50.1： " GATEWAY

            if validate_ipv4 "$GATEWAY"; then
                break
            fi

            network_error "网关格式错误，请重新输入。"

        done

    fi

    if ! validate_ipv4 "$GATEWAY"; then
        network_error "网关格式错误。"
        return 1
    fi

    if ! ipv4_same_subnet "$IP_ADDR" "$GATEWAY" "$PREFIX"; then
        network_error "IP 地址和网关不在同一网段：$IP_ADDR/$PREFIX 与 $GATEWAY"
        network_warn "如需使用非直连网关，请手动配置 onlink 路由。"
        return 1
    fi

    if ! check_ip_conflict "$IFACE" "$IP_ADDR"; then
        return 1
    fi

    echo
    echo "============================================================"
    echo "                       IP 配置确认"
    echo "============================================================"
    echo
    echo "网口：        $IFACE"
    echo "IP 管理方式：  $IP_MANAGER"
    echo "IP：          $IP_ADDR/$PREFIX"
    echo "网关：        $GATEWAY"
    DEFAULT_ROUTE_COUNT="$(ip -4 route show default 2>/dev/null | awk 'END {print NR+0}')"
    if [ "$DEFAULT_ROUTE_COUNT" -gt 1 ]; then
        network_warn "当前存在 $DEFAULT_ROUTE_COUNT 条默认路由，实际出口可能发生变化。"
    fi
    if [ -n "${SSH_CONNECTION:-}" ]; then
        network_warn "当前通过 SSH 连接，修改 IP 可能导致连接中断。"
    fi
    echo

    read -r -p "确认修改？[Y/n] " CONFIRM

    CONFIRM="${CONFIRM:-Y}"

    case "$CONFIRM" in
        Y|y|YES|yes)
            ;;
        *)
            echo "已取消。"
            return 0
            ;;
    esac

    ###########################################################################
    # 按当前管理方式应用配置
    ###########################################################################

    echo
    case "$IP_MANAGER" in
        NetworkManager)
            if ! configure_ip_nm "$IFACE" "$IP_ADDR" "$PREFIX" "$GATEWAY"; then
                return 1
            fi
            ;;

        systemd-networkd)
            write_network_config \
                "$IFACE" \
                "$IP_ADDR" \
                "$PREFIX" \
                "$GATEWAY"

            if ! apply_networkd "$IFACE"; then
                restore_network_config "$IFACE"
                return 1
            fi

            if ! verify_ip_configuration "$IFACE" "$IP_ADDR" "$PREFIX" "$GATEWAY" ||
               ! remove_extra_ipv4 "$IFACE" "$IP_ADDR/$PREFIX" ||
               ! verify_single_ipv4 "$IFACE" "$IP_ADDR/$PREFIX"; then
                network_error "systemd-networkd 配置未达到预期，正在恢复旧配置。"
                restore_network_config "$IFACE"
                return 1
            fi
            ;;

        ifupdown)
            configure_ip_ifupdown "$IFACE" "$IP_ADDR" "$PREFIX" "$GATEWAY" ||
                return 1
            ;;

        *)
            network_error "不支持的 IP 管理方式：$IP_MANAGER"
            return 1
            ;;
    esac

    ###########################################################################
    # 检查
    ###########################################################################

    check_network "$IFACE"
}

###############################################################################
# 检查单个端口
#
# PROTO：
#   tcp
###############################################################################

check_port() {

    local PROTO="$1"
    local PORT="$2"
    local NAME="$3"

    local OUTPUT=""

    # 兼容配置文件、复制粘贴带来的空格、回车和大小写差异。
    PROTO="${PROTO,,}"
    PROTO="${PROTO//$'\r'/}"
    PROTO="${PROTO//[[:space:]]/}"

    case "$PROTO" in

        tcp)

            OUTPUT="$(
                ss -lntp 2>/dev/null |
                grep -E ":${PORT}[[:space:]]" || true
            )

            ;;

        udp_disabled)

            OUTPUT="$(
                ss -lunp 2>/dev/null |
                grep -E ":${PORT}[[:space:]]" || true
            )

            ;;

        *)

            network_error "$NAME：未知协议 $PROTO"
            return 1
            ;;

    esac

    if echo "$OUTPUT" | grep -q "mihomo"; then

        network_pass "$NAME：正常"

        return 0

    fi

    network_error "$NAME：未监听"

    return 1
}

###############################################################################
# 从 Mihomo 配置读取端口
###############################################################################

mihomo_config_value() {

    local KEY="$1"
    local CONFIG="$2"

    case "$KEY" in
        dns.listen)
            awk '
                /^[[:space:]]*listen:/ {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    print
                    exit
                }
            ' "$CONFIG"
            ;;
        *)
            awk -v KEY="$KEY" '
                $0 ~ "^[[:space:]]*" KEY ":[[:space:]]*" {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    print
                    exit
                }
            ' "$CONFIG"
            ;;
    esac |
        sed 's/[[:space:]]*#.*$//' |
        tr -d '"' |
        tr -d "'" |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

port_from_value() {

    local VALUE="$1"

    if [[ "$VALUE" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$VALUE"
    elif [[ "$VALUE" =~ :([0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

check_mihomo_config_port() {

    local KEY="$1"
    local PROTO="$2"
    local NAME="$3"
    local VALUE=""
    local PORT=""

    VALUE="$(mihomo_config_value "$KEY" "$NETWORK_MIHOMO_CONFIG" || true)"
    PORT="$(port_from_value "$VALUE" || true)"

    if [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$PORT" -le 65535 ]; then
        check_port "$PROTO" "$PORT" "$NAME ($PORT)" || true
    else
        network_info "$NAME：未配置"
    fi
}

verify_ip_configuration() {

    local IFACE="$1"
    local IP_ADDR="$2"
    local PREFIX="$3"
    local GATEWAY="$4"

    if ! ip -4 -o addr show dev "$IFACE" |
       awk -v EXPECTED="$IP_ADDR/$PREFIX" '$4 == EXPECTED {found=1} END {exit(found ? 0 : 1)}'; then
        network_error "$IFACE 未检测到目标 IP：$IP_ADDR/$PREFIX"
        return 1
    fi

    if ! ip -4 route show default dev "$IFACE" |
       awk -v GATEWAY="$GATEWAY" '$3 == GATEWAY {found=1} END {exit(found ? 0 : 1)}'; then
        network_error "$IFACE 未检测到目标默认网关：$GATEWAY"
        return 1
    fi

    network_pass "实际 IP 和默认网关验证通过。"
}

remove_extra_ipv4() {

    local IFACE="$1"
    local EXPECTED="$2"
    local ADDRESS=""

    while read -r ADDRESS; do
        [ -n "$ADDRESS" ] || continue
        [ "$ADDRESS" = "$EXPECTED" ] && continue

        if ! ip -4 addr del "$ADDRESS" dev "$IFACE" >/dev/null 2>&1; then
            network_error "无法删除 $IFACE 上的多余 IPv4：$ADDRESS"
            return 1
        fi
    done < <(
        ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null |
        awk '{print $4}' || true
    )
}

verify_single_ipv4() {

    local IFACE="$1"
    local EXPECTED="$2"
    local ADDRESSES=""
    local COUNT=0

    ADDRESSES="$(
        ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null |
        awk '{print $4}' || true
    )"
    COUNT="$(printf '%s\n' "$ADDRESSES" | sed '/^$/d' | wc -l)"

    if [ "$COUNT" -ne 1 ] || [ "$ADDRESSES" != "$EXPECTED" ]; then
        network_error "$IFACE 仍存在多余 IPv4：${ADDRESSES:-无}"
        return 1
    fi

    network_pass "$IFACE 仅保留目标 IPv4：$EXPECTED"
}

check_ip_conflict() {

    local IFACE="$1"
    local IP_ADDR="$2"
    local CURRENT_IPS=""
    local ARP_OUTPUT=""
    local ARP_STATUS=0

    if ! command -v arping >/dev/null 2>&1; then
        network_info "系统没有 arping，跳过 IP 冲突检测。"
        return 0
    fi

    CURRENT_IPS="$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' || true)"
    if printf '%s\n' "$CURRENT_IPS" | grep -q "^$IP_ADDR/"; then
        return 0
    fi

    ARP_OUTPUT="$(arping -D -I "$IFACE" "$IP_ADDR" -c 2 -w 3 2>&1)" || ARP_STATUS=$?

    if ! printf '%s\n' "$ARP_OUTPUT" |
       grep -Eiq 'unicast reply|reply from|duplicate'; then
        if [ "$ARP_STATUS" -ne 0 ]; then
            network_warn "无法完成 IP 冲突检测，继续执行：$IP_ADDR"
            return 0
        fi
        network_pass "未检测到 IP 冲突：$IP_ADDR"
        return 0
    fi

    network_error "检测到 IP 冲突：$IP_ADDR"
    return 1
}

get_expected_ipv4() {

    local IFACE="$1"
    local MANAGER=""
    local CONNECTION=""
    local EXPECTED=""
    local FILE=""

    MANAGER="$(detect_ip_manager "$IFACE" || true)"

    case "$MANAGER" in
        NetworkManager)
            CONNECTION="$(get_nm_connection "$IFACE" || true)"
            if [ -n "$CONNECTION" ]; then
                if [ "$(nmcli -g ipv4.method connection show "$CONNECTION" 2>/dev/null || true)" = "manual" ]; then
                    EXPECTED="$(nmcli -g ipv4.addresses connection show "$CONNECTION" 2>/dev/null | head -n 1 || true)"
                else
                    EXPECTED="DHCP"
                fi
            fi
            ;;
        systemd-networkd)
            for FILE in "$NETWORK_DIR"/*.network; do
                [ -f "$FILE" ] || continue
                if awk -v IFACE="$IFACE" '
                    /^[[:space:]]*\[Match\]/ { in_match=1; next }
                    /^\[/ { in_match=0 }
                    in_match && $0 ~ "^[[:space:]]*Name=" IFACE "([[:space:]]|$)" { found=1 }
                    END { exit(found ? 0 : 1) }
                ' "$FILE"; then
                    EXPECTED="$(awk -F= '/^[[:space:]]*Address=/ {print $2; exit}' "$FILE")"
                    [ -n "$EXPECTED" ] || EXPECTED="DHCP/自动获取"
                    break
                fi
            done
            ;;
        ifupdown)
            FILE="$(ifupdown_config_file "$IFACE" || true)"
            if [ -n "$FILE" ]; then
                EXPECTED="$(awk -v IFACE="$IFACE" '
                    $0 ~ "^[[:space:]]*iface[[:space:]]+" IFACE "[[:space:]]+inet[[:space:]]+" {
                        in_iface=1
                        next
                    }
                    in_iface && /^[[:space:]]*address[[:space:]]+/ {
                        print $2
                        exit
                    }
                    in_iface && /^[^[:space:]#]/ { exit }
                ' "$FILE")"
                [ -n "$EXPECTED" ] || EXPECTED="DHCP/自动获取"
            fi
            ;;
    esac

    printf '%s\n' "$EXPECTED"
}

###############################################################################
# 检查 Mihomo
###############################################################################

check_mihomo() {

    echo
    echo "============================================================"
    echo "                        检查 Mihomo"
    echo "============================================================"

    local MIHOMO_BIN=""
    local NETWORK_MIHOMO_CONFIG="/etc/mihomo/config.yaml"

    if command -v mihomo >/dev/null 2>&1; then

        MIHOMO_BIN="$(command -v mihomo)"

    elif [ -x /usr/local/bin/mihomo ]; then

        MIHOMO_BIN="/usr/local/bin/mihomo"

    fi

    if [ -z "$MIHOMO_BIN" ]; then

        network_error "没有找到 Mihomo。"

        echo
        echo "请先安装 Mihomo，然后重新运行本脚本选择「修改 DNS」。"

        return 1

    fi

    network_pass "找到 Mihomo：$MIHOMO_BIN"

    if systemctl is-active --quiet mihomo 2>/dev/null; then

        network_pass "Mihomo 服务：active"

    else

        network_error "Mihomo 服务没有运行。"
        return 1

    fi

    echo
    echo "检查 Mihomo 53 端口："

    local TCP53=""

    TCP53="$(
        ss -lntp 2>/dev/null |
        grep -E ":53[[:space:]]" |
        grep mihomo || true
    )"

    if [ -n "$TCP53" ]; then

        network_pass "检测到 Mihomo TCP 53 端口。"

        echo "$TCP53"

        return 0

    fi

    network_error "没有检测到 Mihomo 53 端口监听。"

    echo
    echo "请确认 /etc/mihomo/config.yaml："
    echo
    echo "dns:"
    echo "  enable: true"
    echo "  listen: 0.0.0.0:53"
    echo

    return 1
}

###############################################################################
# 安全写入 resolv.conf
###############################################################################

write_resolv_conf() {

    local CONTENT="$1"
    local BACKUP=""
    local TEMP_FILE=""

    if [ -L "$RESOLV_CONF" ]; then
        network_error "$RESOLV_CONF 是软链接，未修改。"
        network_warn "当前指向：$(readlink -f "$RESOLV_CONF" 2>/dev/null || echo 未知)"
        network_warn "请先配置 systemd-resolved/NetworkManager，或手动确认后再由脚本接管。"
        return 1
    fi

    if [ -e "$RESOLV_CONF" ]; then
        BACKUP="${RESOLV_CONF}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$RESOLV_CONF" "$BACKUP"
        network_pass "原 resolv.conf 已备份：$BACKUP"
    fi

    TEMP_FILE="$(mktemp /etc/.resolv.conf.XXXXXX)"
    printf '%s\n' "$CONTENT" > "$TEMP_FILE"
    chmod 644 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$RESOLV_CONF"
}

###############################################################################
# 修改 DNS
###############################################################################

configure_dns() {

    while true; do

        echo
        echo "============================================================"
        echo "                         DNS 配置"
        echo "============================================================"
        echo
        echo "1. DNS → Mihomo"
        echo "2. 自定义 DNS"
        echo "0. 返回"
        echo

        read -r -p "请选择 [0-2]： " DNS_CHOICE

        case "$DNS_CHOICE" in

            ###################################################################
            # Mihomo DNS
            ###################################################################

            1)

                echo
                echo "============================================================"
                echo "                         DNS → Mihomo"
                echo "============================================================"

                if ! check_mihomo; then

                    echo
                    network_warn "Mihomo DNS 未通过检查。"
                    network_warn "DNS 未修改。"

                    continue

                fi

                echo
                echo "将设置："
                echo
                echo "/etc/resolv.conf"
                echo "        ↓"
                echo "nameserver 127.0.0.1"
                echo

                read -r -p "确认修改 DNS？[Y/n] " CONFIRM

                CONFIRM="${CONFIRM:-Y}"

                case "$CONFIRM" in
                    Y|y|YES|yes)
                        ;;
                    *)
                        echo "已取消。"
                        continue
                        ;;
                esac

                if ! write_resolv_conf "nameserver 127.0.0.1"; then
                    network_warn "DNS 未修改。"
                    continue
                fi

                network_pass "本机 DNS 已设置为 127.0.0.1"

                ################################################################
                # 测试
                ################################################################

                echo

                if getent hosts www.baidu.com >/dev/null 2>&1; then

                    network_pass "DNS 解析正常。"

                else

                    network_warn "DNS 解析失败。"

                fi

                ;;

            ###################################################################
            # 自定义 DNS
            ###################################################################

            2)

                echo
                echo "============================================================"
                echo "                         自定义 DNS"
                echo "============================================================"
                echo
                echo "请输入 DNS 服务器。"
                echo
                echo "例如："
                echo "  192.168.50.1"
                echo "  223.5.5.5"
                echo "  1.1.1.1"
                echo
                echo "支持多个 DNS，每行一个。"
                echo "输入空行结束。"
                echo

                local DNS_LIST=""
                local DNS=""

                while true; do

                    read -r -p "DNS： " DNS

                    if [ -z "$DNS" ]; then
                        break
                    fi

                    if ! validate_ipv4 "$DNS"; then

                        network_error "DNS 地址格式错误：$DNS"
                        continue

                    fi

                    if [ -n "$DNS_LIST" ]; then

                        DNS_LIST="${DNS_LIST}"$'\n'"${DNS}"

                    else

                        DNS_LIST="$DNS"

                    fi

                done

                if [ -z "$DNS_LIST" ]; then

                    network_warn "没有输入 DNS，操作取消。"
                    continue

                fi

                echo
                echo "============================================================"
                echo "                       DNS 配置确认"
                echo "============================================================"
                echo

                echo "$DNS_LIST"

                echo

                read -r -p "确认写入？[Y/n] " CONFIRM

                CONFIRM="${CONFIRM:-Y}"

                case "$CONFIRM" in

                    Y|y|YES|yes)
                        ;;

                    *)
                        echo "已取消。"
                        continue
                        ;;

                esac

                local RESOLV_CONTENT="# 由 Mihomo 网络配置菜单配置"

                while IFS= read -r DNS; do
                    [ -n "$DNS" ] || continue
                    RESOLV_CONTENT+=$'\nnameserver '"$DNS"
                done <<< "$DNS_LIST"

                if ! write_resolv_conf "$RESOLV_CONTENT"; then
                    network_warn "DNS 未修改。"
                    continue
                fi

                network_pass "自定义 DNS 已写入。"

                echo
                echo "当前 /etc/resolv.conf："

                cat "$RESOLV_CONF"

                ################################################################
                # 测试
                ################################################################

                echo

                if getent hosts www.baidu.com >/dev/null 2>&1; then

                    network_pass "DNS 解析正常。"

                else

                    network_warn "DNS 解析失败，请检查 DNS 地址。"

                fi

                ;;

            ###################################################################
            # 返回
            ###################################################################

            0)

                return 0
                ;;

            *)

                network_warn "无效选项，请输入 0-2。"
                ;;

        esac

        echo
        read -r -p "按 Enter 返回 DNS 菜单……" _

        clear 2>/dev/null || true

    done
}

###############################################################################
# 完整网络检查
###############################################################################

check_network() {

    local IFACE="$1"
    local IP_MANAGER=""
    local EXPECTED_IPV4=""

    CHECK_MODE=1
    CHECK_ISSUES=0

    echo
    echo "============================================================"
    echo "                     完整网络检查"
    echo "============================================================"

    ###########################################################################
    # 网络
    ###########################################################################

    echo
    echo "【网络】"

    echo "网卡：        $IFACE"

    local LINK_STATE=""

    LINK_STATE="$(
        ip -br link show "$IFACE" 2>/dev/null |
        awk '{print $2}'
    )"

    if [[ "$LINK_STATE" == *UP* ]]; then
        network_pass "网卡状态：UP"
    else
        network_warn "网卡状态：$LINK_STATE"
    fi

    ###########################################################################
    # IPv4
    ###########################################################################

    echo
    echo "【IPv4】"

    mapfile -t IPV4_LIST < <(
        ip -4 -o addr show dev "$IFACE" |
        awk '{print $4}'
    )

    local IP_COUNT="${#IPV4_LIST[@]}"
    local PRIMARY_IP=""
    local PRIMARY_IP_ADDR=""
    local EXPECTED_IP_ADDR=""
    EXPECTED_IPV4="$(get_expected_ipv4 "$IFACE" || true)"

    if [ "$IP_COUNT" -gt 0 ]; then

        PRIMARY_IP="${IPV4_LIST[0]}"
        PRIMARY_IP_ADDR="${PRIMARY_IP%%/*}"

        echo "IP：          $PRIMARY_IP"

    else

        echo "IP：          无"

    fi

    echo "IPv4 数量：   $IP_COUNT"

    if [ "$IP_COUNT" -eq 1 ]; then

        network_pass "当前只有一个 IPv4。"

    elif [ "$IP_COUNT" -gt 1 ]; then

        network_warn "检测到多个 IPv4，存在双 IP / 多 IP。"

        for IP in "${IPV4_LIST[@]}"; do
            echo "              $IP"
        done

    else

        network_warn "当前没有 IPv4。"

    fi

    echo "配置 IPv4：   ${EXPECTED_IPV4:-未读取}"

    if [ -n "$PRIMARY_IP" ] &&
       [ "$EXPECTED_IPV4" != "DHCP" ] &&
       [ "$EXPECTED_IPV4" != "DHCP/自动获取" ]; then
        EXPECTED_IP_ADDR="${EXPECTED_IPV4%%/*}"
        if [ "$PRIMARY_IP_ADDR" = "$EXPECTED_IP_ADDR" ]; then
            network_pass "实际 IPv4 与配置一致。"
        else
            network_warn "实际 IPv4 与配置不一致。"
        fi
    fi

    ###########################################################################
    # 网段
    ###########################################################################

    local LAN_NETWORK=""

    LAN_NETWORK="$(
        ip -4 route show dev "$IFACE" scope link 2>/dev/null |
        awk '$1 != "default" {print $1; exit}' || true
    )"

    if [ -n "$LAN_NETWORK" ]; then
        echo "网段：        $LAN_NETWORK"
    fi

    ###########################################################################
    # 路由
    ###########################################################################

    echo
    echo "【路由】"

    mapfile -t DEFAULT_ROUTES < <(
        ip -4 route show default 2>/dev/null
    )

    local ROUTE_COUNT="${#DEFAULT_ROUTES[@]}"

    echo "默认路由数量：$ROUTE_COUNT"

    if [ "$ROUTE_COUNT" -eq 1 ]; then

        network_pass "默认路由正常。"

    elif [ "$ROUTE_COUNT" -gt 1 ]; then

        network_warn "检测到多个默认路由。"

    else

        network_warn "没有检测到默认路由。"

    fi

    local ROUTE=""

    for ROUTE in "${DEFAULT_ROUTES[@]}"; do
        echo "路由：        $ROUTE"
    done

    ###########################################################################
    # 网关
    ###########################################################################

    echo
    echo "【网关】"

    local GATEWAY=""
    local GATEWAY_IF=""

    GATEWAY="$(
        ip -4 route show default 2>/dev/null |
        awk 'NR==1 {print $3}'
    )"

    GATEWAY_IF="$(
        ip -4 route show default 2>/dev/null |
        awk 'NR==1 {print $5}'
    )"

    if [ -n "$GATEWAY" ]; then

        echo "网关：        $GATEWAY"
        echo "网关接口：    $GATEWAY_IF"

        if [ "$GATEWAY_IF" = "$IFACE" ]; then
            network_pass "网关接口正确。"
        else
            network_warn "网关接口不是 $IFACE。"
        fi

        echo
        echo "测试网关：    $GATEWAY"

        if ping -c 2 -W 2 "$GATEWAY" >/dev/null 2>&1; then
            network_pass "网关可以正常访问。"
        else
            network_warn "网关无法通过 ICMP 访问。"
        fi

    else

        network_warn "没有检测到网关。"

    fi

    echo
    echo "【公网连通性】"

    if ping -c 2 -W 2 1.1.1.1 >/dev/null 2>&1; then
        network_pass "公网 IP 连通正常（1.1.1.1）。"
    else
        network_warn "公网 IP 不可达；可能是路由、防火墙或运营商限制。"
    fi

    ###########################################################################
    # ARP / 邻居
    ###########################################################################

    echo
    echo "【ARP / 邻居】"

    if [ -n "$GATEWAY" ]; then

        local NEIGH=""

        NEIGH="$(
            ip neigh show "$GATEWAY" dev "$IFACE" 2>/dev/null || true
        )"

        if [ -n "$NEIGH" ]; then

            echo "$NEIGH"

            if echo "$NEIGH" | grep -q "lladdr"; then
                network_pass "网关 MAC 地址已解析。"
            else
                network_warn "网关 MAC 地址尚未正常解析。"
            fi

        else

            network_warn "没有找到网关邻居记录。"

        fi

    fi

    ###########################################################################
    # 网络管理
    ###########################################################################

    echo
    echo "【网络管理】"

    local NETWORKD_STATE=""

    NETWORKD_STATE="$(
        systemctl is-active systemd-networkd 2>/dev/null || true
    )"

    echo "systemd-networkd：$NETWORKD_STATE"

    if [ "$NETWORKD_STATE" = "active" ]; then
        network_pass "systemd-networkd 正常运行。"
    fi

    echo
    echo "networkctl："

    networkctl status "$IFACE" --no-pager 2>/dev/null |
        grep -E \
        'State:|Online state:|Network File:|Address:|Gateway:|DNS:|Activation Policy:' \
        || true

    check_nm "$IFACE"

    IP_MANAGER="$(detect_ip_manager "$IFACE" || true)"

    if [ -n "$IP_MANAGER" ]; then
        network_pass "实际 IP 管理方式：$IP_MANAGER"
    else
        network_warn "无法确认实际 IP 管理方式。"
    fi

    ###########################################################################
    # DNS
    ###########################################################################

    echo
    echo "【DNS】"

    local DNS_SERVER=""
    local DNS_SERVERS=""

    if [ -f "$RESOLV_CONF" ]; then

        if [ -L "$RESOLV_CONF" ]; then
            echo "resolv.conf：  软链接 → $(readlink -f "$RESOLV_CONF")"
        else
            echo "resolv.conf：  普通文件"
        fi

        DNS_SERVERS="$(awk '/^[[:space:]]*nameserver[[:space:]]+/ {print $2}' "$RESOLV_CONF")"

        DNS_SERVER="$(
            awk '/^nameserver / {print $2; exit}' "$RESOLV_CONF"
        )"

        echo "DNS：          ${DNS_SERVERS:-无}"

        if [ "$DNS_SERVER" = "127.0.0.1" ]; then
            network_pass "/etc/resolv.conf → 127.0.0.1"
            network_pass "当前使用 Mihomo DNS。"
        elif [ -n "$DNS_SERVER" ]; then
            network_pass "当前使用自定义 DNS：$DNS_SERVER"
        else
            network_warn "/etc/resolv.conf 没有有效的 nameserver。"
        fi

    else

        network_warn "/etc/resolv.conf 不存在。"

    fi

    ###########################################################################
    # Mihomo
    ###########################################################################

    echo
    echo "【Mihomo】"

    local MIHOMO_BIN=""
    local NETWORK_MIHOMO_SERVICE="inactive"
    local NETWORK_MIHOMO_CONFIG="/etc/mihomo/config.yaml"

    if command -v mihomo >/dev/null 2>&1; then

        MIHOMO_BIN="$(command -v mihomo)"

    elif [ -x /usr/local/bin/mihomo ]; then

        MIHOMO_BIN="/usr/local/bin/mihomo"

    fi

    if [ -n "$MIHOMO_BIN" ]; then

        network_pass "Mihomo：$MIHOMO_BIN"

    else

        network_error "没有找到 Mihomo。"

    fi

    if systemctl is-active --quiet mihomo 2>/dev/null; then

        NETWORK_MIHOMO_SERVICE="active"

        echo "服务：        active"
        network_pass "Mihomo 服务 active"

    else

        echo "服务：        inactive"
        network_warn "Mihomo 服务未运行。"

    fi

    echo "配置：        $NETWORK_MIHOMO_CONFIG"

    ###########################################################################
    # Fake-IP / DNS 配置
    ###########################################################################

    local FAKE_IP_RANGE=""
    local DNS_LISTEN=""

    if [ -f "$NETWORK_MIHOMO_CONFIG" ]; then

        FAKE_IP_RANGE="$(
            awk -F': ' '
                /fake-ip-range:/ {
                    print $2
                    exit
                }
            ' "$NETWORK_MIHOMO_CONFIG" |
            tr -d '"' |
            tr -d "'" || true
        )"

        DNS_LISTEN="$(
            awk '
                /^  listen:/ {
                    print $2
                    exit
                }
            ' "$NETWORK_MIHOMO_CONFIG" |
            tr -d '"' |
            tr -d "'" || true
        )"

        if [ -n "$FAKE_IP_RANGE" ]; then
            echo "Fake-IP：     $FAKE_IP_RANGE"
        fi

        if [ -n "$DNS_LISTEN" ]; then
            echo "DNS监听：     $DNS_LISTEN"
        fi

    fi

    ###########################################################################
    # Mihomo 端口
    ###########################################################################

    echo
    echo "【Mihomo 端口】"

    if [ -f "$NETWORK_MIHOMO_CONFIG" ]; then
        check_mihomo_config_port dns.listen tcp "DNS TCP"
        check_mihomo_config_port mixed-port tcp "Mixed TCP"
        check_mihomo_config_port port tcp "HTTP 代理 TCP"
        check_mihomo_config_port socks-port tcp "SOCKS 代理 TCP"
        check_mihomo_config_port redir-port tcp "透明代理 TCP"
        check_mihomo_config_port external-controller tcp "控制端口 TCP"
    else
        network_warn "未找到 Mihomo 配置，无法读取实际端口。"
    fi

    ###########################################################################
    # DNS 实际测试
    ###########################################################################

    echo
    echo "【DNS 实际测试】"

    local BAIDU_RESULT=""
    local GOOGLE_RESULT=""

    if command -v getent >/dev/null 2>&1; then

        BAIDU_RESULT="$(
            getent hosts www.baidu.com 2>/dev/null |
            head -n 1 || true
        )"

        GOOGLE_RESULT="$(
            getent hosts www.google.com 2>/dev/null |
            head -n 1 || true
        )"

        if [ -n "$BAIDU_RESULT" ]; then

            network_pass "www.baidu.com：解析正常"
            echo "              $BAIDU_RESULT"

        else

            network_warn "www.baidu.com：解析失败"

        fi

        if [ -n "$GOOGLE_RESULT" ]; then

            network_pass "www.google.com：解析正常"
            echo "              $GOOGLE_RESULT"

        else

            network_warn "www.google.com：解析失败"

        fi

    fi

    ###########################################################################
    # Fake-IP
    ###########################################################################

    echo
    echo "【Fake-IP】"

    if echo "$GOOGLE_RESULT" |
       grep -Eq '198\.18\.[0-9]+\.[0-9]+'; then

        local FAKE_RESULT=""

        FAKE_RESULT="$(
            echo "$GOOGLE_RESULT" |
            awk '{print $1}'
        )"

        network_pass "Fake-IP 正常：$FAKE_RESULT"

    else

        network_warn "www.google.com 未返回 198.18.0.0/16 Fake-IP。"

    fi

    ###########################################################################
    # 摘要
    ###########################################################################

    echo
    echo "============================================================"
    echo "                       检查摘要"
    echo "============================================================"

    echo
    echo "网络"
    echo "├── 网卡：        $IFACE"
    echo "├── IP 管理：     ${IP_MANAGER:-未识别}"
    echo "├── IP：          ${PRIMARY_IP:-无}"
    echo "├── 配置 IP：      ${EXPECTED_IPV4:-未读取}"
    echo "├── 网关：        ${GATEWAY:-无}"
    echo "├── 默认路由：    $ROUTE_COUNT 条"

    if [ "$IP_COUNT" -eq 1 ]; then
        echo "└── 双 IP：       不存在"
    elif [ "$IP_COUNT" -gt 1 ]; then
        echo "└── 双 IP：       存在"
    else
        echo "└── 双 IP：       无 IPv4"
    fi

    echo
    echo "DNS"
    echo "├── resolv.conf： ${DNS_SERVERS:-无}"
    echo "├── Mihomo DNS：  ${DNS_LISTEN:-未读取}"

    if [ -n "$BAIDU_RESULT" ]; then
        echo "├── DNS 查询：    正常"
    else
        echo "├── DNS 查询：    失败"
    fi

    echo "└── Fake-IP：     ${FAKE_IP_RANGE:-未读取}"

    echo
    echo "Mihomo"
    echo "├── 服务：        $NETWORK_MIHOMO_SERVICE"
    echo "└── 端口：        按 config.yaml 实际配置检查"

    echo
    if [ "$CHECK_ISSUES" -eq 0 ]; then
        printf '%s检查结果：      通过%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    else
        printf '%s检查结果：      发现 %s 个问题或警告%s\n' \
            "$COLOR_YELLOW" "$CHECK_ISSUES" "$COLOR_RESET"
    fi

    echo
    echo "============================================================"

    CHECK_MODE=0
}


###############################################################################
# 网络设置菜单
###############################################################################

network_menu() {

    clear 2>/dev/null || true

    ACTIVE_IF="$(detect_interface || true)"
    if [ -z "$ACTIVE_IF" ]; then
        network_error "无法自动识别网口。"
        ip -br link 2>/dev/null || true
        read -r -p "按回车键返回主菜单..." _
        return 0
    fi

    network_pass "自动识别网口：$ACTIVE_IF"

    while true; do
        show_network_menu
        read -r -p "请选择 [0-4]： " CHOICE

        case "$CHOICE" in
            1)
                configure_ip "$ACTIVE_IF"
                ;;
            2)
                configure_dns
                ;;
            3)
                configure_ip "$ACTIVE_IF"
                echo
                configure_dns
                ;;
            4)
                check_network "$ACTIVE_IF"
                ;;
            0)
                echo "退出网络设置。"
                return 0
                ;;
            *)
                network_warn "无效选项，请输入 0-4。"
                ;;
        esac

        echo
        read -r -p "按 Enter 返回网络菜单……" _
        clear 2>/dev/null || true
    done
}


###############################################################################
# 交互菜单
###############################################################################

show_network_menu() {

    echo
    echo "============================================================"
    echo " 网络设置"
    echo "============================================================"
    echo " 自动识别网口：$ACTIVE_IF"
    echo
    echo "  1. 修改 IP"
    echo "  2. 修改 DNS"
    echo "  3. 修改 IP + DNS"
    echo "  4. 查看当前网络状态"
    echo "  0. 退出"
    echo
}

show_menu() {

    while true; do
        clear 2>/dev/null || true

        echo
        echo "============================================================"
        echo " Mihomo Pure TProxy 管理菜单"
        echo "============================================================"
        echo "  1. 安装 / 更新"
        echo "  2. 卸载"
        echo "  3. 检测运行状态"
        echo "  4. 网络设置（IP / DNS）"
        echo "  0. 退出"
        echo
        read -r -p "请输入选项 [0-4]：" choice
        echo

        case "$choice" in
            1)
                check_root
                install_main
                read -r -p "按回车键返回菜单..." _
                ;;

            2)
                check_root
                read -r -p "确定要卸载 Mihomo Pure TProxy 吗？[y/N]：" confirm
                case "$confirm" in
                    y|Y|yes|YES)
                        uninstall
                        ;;
                    *)
                        echo "已取消卸载。"
                        ;;
                esac
                read -r -p "按回车键返回菜单..." _
                ;;

            3)
                check_root
                full_check || true
                read -r -p "按回车键返回菜单..." _
                ;;

            4)
                check_root
                network_menu
                ;;

            0|q|Q)
                echo "已退出。"
                return 0
                ;;

            *)
                echo "无效选项，请输入 0、1、2、3 或 4。"
                read -r -p "按回车键继续..." _
                ;;
        esac
    done
}


###############################################################################
# 卸载
###############################################################################

uninstall() {

    log "卸载 Mihomo Pure TProxy"

    systemctl stop mihomo 2>/dev/null || true
    systemctl stop mihomo-policy 2>/dev/null || true

    restore_dns_state


    systemctl disable mihomo 2>/dev/null || true
    systemctl disable mihomo-policy 2>/dev/null || true


    #
    # 删除策略路由
    #

    while ip rule show |
        grep -Eq "fwmark ${MARK}.*lookup ${TABLE}"; do

        ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null ||
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

    if [ -f "$NFT_CONF_BACKUP_FILE" ]; then
        cp -a "$NFT_CONF_BACKUP_FILE" /etc/nftables.conf
    elif [ -f /etc/nftables.conf ]; then
        #
        # 兼容旧版本安装时带缩进的 include 行，
        # 因此必须允许行首出现空白字符。
        #
        sed -i '\|^[[:space:]]*include "/etc/nftables.d/\*\.nft"[[:space:]]*$|d' \
            /etc/nftables.conf
    fi


    # 恢复安装前保存的 sysctl 值
    restore_sysctl_state


    systemctl daemon-reload

    ok "TProxy 已卸载"

}


###############################################################################
# 安装
###############################################################################

install_main() {

    check_root
    detect_arch
    check_system
    install_dependencies
    check_runtime_dependencies
    detect_lan_network

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

    create_directories

    #
    # 必须先创建用户，再安装 config。
    #

    create_mihomo_user

    install_mihomo
    
    install_config
    
    check_config
    
    check_required_config
    
    check_tproxy_support
    
    check_dns_port
         
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

    configure_local_dns

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

    menu)

        show_menu

        ;;

    install)

        check_root
        install_main

        ;;


    check)

        check_root
        full_check

        ;;


    network)

        check_root
        network_menu

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
        echo "      进入管理菜单"
        echo
        echo "  $0 check"
        echo "      检查运行状态"
        echo
        echo "  $0 uninstall"
        echo "      卸载"
        echo
        echo "  $0 network"
        echo "      网络设置（IP / DNS）"
        echo

        ;;


    *)

        echo "未知参数：$ACTION"
        exit 1

        ;;

esac
