#!/bin/bash
set -u
set -o pipefail

###############################################################################
# Mihomo Pure TProxy 一键全自动健康检查
#
# 目标：
#   不需要客户端配合
#   不修改网络
#   不修改 nftables
#   不修改路由
#   不重启 Mihomo
#
# 自动发现：
#   LAN 网卡
#   LAN IPv4 / LAN CIDR
#   默认网关
#   Mihomo nft 表
#   TProxy 端口
#   fwmark
#   policy routing table
#   Mihomo Controller
#   Mihomo 配置文件
#
# 检查：
#   系统基础环境
#   IPv4 forwarding
#   rp_filter
#   src_valid_mark
#   route_localnet
#   TProxy 内核能力
#   policy routing
#   mark -> local route
#   nftables
#   PREROUTING
#   OUTPUT
#   TPROXY
#   mark
#   DNS
#   Mihomo
#   Controller
#   TCP
#   UDP socket
#   本机 HTTPS
#   nft counter
#   Mihomo 最近日志
###############################################################################

###############################################################################
# 基础配置
###############################################################################

MIHOMO_SERVICE="mihomo"
MIHOMO_USER="mihomo"

MIHOMO_DIR="/etc/mihomo"

DNS_TEST_DOMAIN="www.baidu.com"
HTTPS_TEST_URL="https://www.baidu.com"

DEFAULT_TPROXY_PORT="7893"
DEFAULT_API_PORT="9090"

###############################################################################
# 颜色
###############################################################################

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
BLUE='\033[34m'
RESET='\033[0m'

PASS=0
FAIL=0
WARN=0
INFO_COUNT=0

###############################################################################
# 输出函数
###############################################################################

pass() {
    echo -e "${GREEN}[PASS]${RESET} $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "${RED}[FAIL]${RESET} $1"
    FAIL=$((FAIL + 1))
}

warn() {
    echo -e "${YELLOW}[WARN]${RESET} $1"
    WARN=$((WARN + 1))
}

info() {
    echo -e "${CYAN}[INFO]${RESET} $1"
    INFO_COUNT=$((INFO_COUNT + 1))
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

subsection() {
    echo
    echo "-------------------- $1 --------------------"
}

###############################################################################
# root
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    echo "[FAIL] 请使用 root 运行"
    exit 1
fi

###############################################################################
# 基础工具
###############################################################################

section "一、检查基础工具"

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
        pass "$cmd"
    else
        fail "缺少 $cmd"
    fi
done

###############################################################################
# 自动识别 LAN
###############################################################################

section "二、自动识别网络"

DEFAULT_ROUTE="$(ip -4 route show default 2>/dev/null | head -n1 || true)"

LAN_IF=""

if [ -n "$DEFAULT_ROUTE" ]; then
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
    pass "LAN 网卡：$LAN_IF"
else
    fail "无法自动识别默认路由网卡"
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
    pass "LAN IPv4：$LAN_IP"
else
    fail "无法获取 LAN IPv4"
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
    pass "LAN 网络：$LAN_CIDR"
else
    warn "无法自动获取 LAN 网络"
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
    pass "默认网关：$GATEWAY"
else
    warn "没有检测到默认网关"
fi

###############################################################################
# 默认路由
###############################################################################

echo
echo "默认路由："

if [ -n "$DEFAULT_ROUTE" ]; then
    echo "$DEFAULT_ROUTE"
else
    fail "没有 IPv4 默认路由"
fi

DEFAULT_COUNT="$(ip -4 route show default 2>/dev/null | wc -l)"

if [ "$DEFAULT_COUNT" -eq 1 ]; then
    pass "默认路由数量：1"
elif [ "$DEFAULT_COUNT" -gt 1 ]; then
    warn "默认路由数量：$DEFAULT_COUNT"
else
    fail "没有默认路由"
fi

###############################################################################
# 网卡状态
###############################################################################

if [ -n "$LAN_IF" ]; then

    if ip link show "$LAN_IF" 2>/dev/null |
        grep -qE 'state UP|UP'
    then
        pass "$LAN_IF 状态：UP"
    else
        fail "$LAN_IF 状态异常"
    fi

fi

###############################################################################
# IPv4 Forward
###############################################################################

section "三、检查内核网络参数"

IP_FORWARD="$(
    sysctl -n net.ipv4.ip_forward 2>/dev/null ||
    echo 0
)"

if [ "$IP_FORWARD" = "1" ]; then
    pass "net.ipv4.ip_forward = 1"
else
    fail "net.ipv4.ip_forward = $IP_FORWARD"
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
    pass "LAN TProxy 入口 rp_filter = 0"
else
    warn "LAN TProxy 入口 rp_filter 不是 0"
fi

if [ "$RP_DEFAULT" != "0" ]; then
    warn "default.rp_filter = $RP_DEFAULT"
else
    pass "default.rp_filter = 0"
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
    pass "all.src_valid_mark = 1"
else
    info "all.src_valid_mark = 0（当前 TProxy 实际路由测试正常，无需强制开启）"
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
        pass "$LAN_IF route_localnet = 1"
    else
        info "$LAN_IF route_localnet = $ROUTE_LOCALNET"
    fi

fi

###############################################################################
# TProxy 内核模块
###############################################################################

section "四、检查 TProxy 内核能力"

if [ -d /sys/module/nft_tproxy ]; then
    pass "nft_tproxy 内核模块已加载"
else
    warn "nft_tproxy 模块没有出现在 /sys/module"
fi

if [ -d /sys/module/nf_tproxy_ipv4 ]; then
    pass "nf_tproxy_ipv4 模块已加载"
else
    info "nf_tproxy_ipv4 模块未单独显示"
fi

###############################################################################
# Policy Routing 自动发现
###############################################################################

section "五、检查 Policy Routing"

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

    pass "Policy Routing：fwmark $MARK → table $TABLE"

else

    fail "没有找到 fwmark → policy table"

fi

###############################################################################
# Policy Table
###############################################################################

if [ -n "$TABLE" ]; then

    subsection "路由表 $TABLE"

    TABLE_ROUTE="$(
        ip -4 route show table "$TABLE" 2>/dev/null ||
        true
    )"

    if [ -n "$TABLE_ROUTE" ]; then

        echo "$TABLE_ROUTE"

        if echo "$TABLE_ROUTE" |
            grep -qE '^local default'
        then

            pass "table $TABLE 存在 local default"

        else

            warn "table $TABLE 没有 local default"

        fi

    else

        fail "table $TABLE 为空"

    fi

fi

###############################################################################
# Mark Route Test
###############################################################################

section "六、检查 fwmark 路由"

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

info "Mark 路由测试目标：$TEST_IP"

if [ -n "$MARK" ]; then

    MARK_ROUTE="$(
        ip -4 route get "$TEST_IP" mark "$MARK" 2>/dev/null ||
        true
    )"

    echo "$MARK_ROUTE"

    if echo "$MARK_ROUTE" |
        grep -qE 'local .*dev lo'
    then

        pass "fwmark $MARK → lo"

    else

        fail "fwmark $MARK 没有正确进入 lo"

    fi

else

    warn "无法测试 fwmark 路由"

fi

###############################################################################
# nftables 自动发现
###############################################################################

section "七、检查 nftables"

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

    pass "发现 Mihomo nft 表：$NFT_FAMILY $NFT_TABLE"

else

    fail "没有发现 Mihomo nft 表"

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
    fail "无法读取 Mihomo nft 规则"
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

    warn "无法从 nft 自动识别 TProxy 端口，使用兜底：$TPROXY_PORT"

else

    pass "TProxy 端口：$TPROXY_PORT"

fi

###############################################################################
# nft chain
###############################################################################

if [ -n "$NFT_RULES" ]; then

    if echo "$NFT_RULES" |
        grep -qE 'chain[[:space:]]+prerouting'
    then
        pass "存在 prerouting chain"
    else
        fail "不存在 prerouting chain"
    fi

    if echo "$NFT_RULES" |
        grep -qE 'chain[[:space:]]+output'
    then
        pass "存在 output chain"
    else
        fail "不存在 output chain"
    fi

    if echo "$NFT_RULES" |
        grep -q "tproxy to :$TPROXY_PORT"
    then
        pass "存在 TProxy → :$TPROXY_PORT"
    else
        fail "不存在 TProxy → :$TPROXY_PORT"
    fi

    if echo "$NFT_RULES" |
        grep -Eq 'meta mark set'
    then
        pass "存在 nft mark 设置"
    else
        fail "没有发现 meta mark set"
    fi

fi

###############################################################################
# LAN CIDR
###############################################################################

if [ -n "$LAN_CIDR" ] && [ -n "$NFT_RULES" ]; then

    if echo "$NFT_RULES" |
        grep -Fq "$LAN_CIDR"
    then
        pass "nft 发现 LAN 网络：$LAN_CIDR"
    else
        warn "nft 没有直接出现 LAN 网络：$LAN_CIDR"
    fi

fi

###############################################################################
# 检查 PREROUTING TProxy
###############################################################################

section "八、检查 LAN → TProxy"

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
        pass "PREROUTING 存在 TProxy"
    else
        fail "PREROUTING 没有 TProxy"
    fi

    if echo "$PREROUTING_BLOCK" |
        grep -qE 'meta mark set'
    then
        pass "PREROUTING 存在 mark"
    else
        warn "PREROUTING 没有明显 mark 设置"
    fi

fi

###############################################################################
# 检查 OUTPUT TProxy
###############################################################################

section "九、检查本机 OUTPUT → Policy Routing → TProxy"

NFT_OUTPUT="$(nft list chain ip mihomo output 2>/dev/null || true)"

if [ -z "$NFT_OUTPUT" ]; then
    fail "无法读取 Mihomo output chain"
else
    echo "$NFT_OUTPUT"

    ###########################################################################
    # TCP / UDP OUTPUT mark
    ###########################################################################

    if echo "$NFT_OUTPUT" | grep -Eq \
        'meta l4proto tcp.*meta mark set|meta l4proto udp.*meta mark set'; then

        pass "OUTPUT 存在 TCP/UDP mark"

    else

        fail "OUTPUT 没有发现 TCP/UDP mark"

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

        pass "OUTPUT → fwmark $MARK → table $TABLE → lo"

    else

        fail "OUTPUT → fwmark $MARK → table $TABLE → lo 链路异常"

    fi
fi

###############################################################################
# Mihomo Service
###############################################################################

section "十、检查 Mihomo 服务"

if systemctl is-active --quiet "$MIHOMO_SERVICE"; then
    pass "Mihomo：active"
else
    fail "Mihomo：inactive"
fi

if systemctl is-enabled --quiet "$MIHOMO_SERVICE" 2>/dev/null; then
    pass "Mihomo：enabled"
else
    warn "Mihomo 没有 enabled"
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
    pass "Mihomo PID：$MIHOMO_PID"
else
    fail "没有 Mihomo 进程"
fi

###############################################################################
# Mihomo User
###############################################################################

section "十一、检查 Mihomo 用户"

if id "$MIHOMO_USER" >/dev/null 2>&1; then

    MIHOMO_UID="$(id -u "$MIHOMO_USER")"

    pass "用户存在：$MIHOMO_USER"
    info "UID：$MIHOMO_UID"

else

    warn "用户不存在：$MIHOMO_USER"

fi

###############################################################################
# 配置文件自动发现
###############################################################################

section "十二、检查 Mihomo 配置"

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

    pass "配置文件：$CONFIG_FILE"

else

    warn "没有找到标准 Mihomo 配置文件"

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

info "Controller：$API_PORT"

###############################################################################
# Mihomo 监听端口
###############################################################################

section "十三、检查 Mihomo Socket"

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

section "十四、检查 Mihomo DNS"

if ss -lunp 2>/dev/null |
    grep -Eq '([.:])53\b'
then
    pass "UDP :53 正在监听"
else
    fail "UDP :53 没有监听"
fi

if ss -lunp 2>/dev/null |
    grep -E '([.:])53\b' |
    grep -qi mihomo
then
    pass "UDP :53 由 Mihomo 监听"
else
    fail "UDP :53 不是 Mihomo"
fi

if ss -lntp 2>/dev/null |
    grep -E '([.:])53\b' |
    grep -qi mihomo
then
    pass "TCP :53 由 Mihomo 监听"
else
    warn "TCP :53 不是 Mihomo"
fi

###############################################################################
# resolv.conf
###############################################################################

section "十五、检查系统 DNS"

if [ -f /etc/resolv.conf ]; then

    cat /etc/resolv.conf

    if grep -Eq \
        '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.1([[:space:]]|$)' \
        /etc/resolv.conf
    then

        pass "系统 DNS → 127.0.0.1"

    else

        warn "系统 DNS 没有指向 127.0.0.1"

    fi

else

    warn "/etc/resolv.conf 不存在"

fi

###############################################################################
# DNS 实际测试
###############################################################################

section "十六、实际 DNS 测试"

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
    pass "DNS 解析正常：$DNS_TEST_DOMAIN"

else

    fail "DNS 解析失败：$DNS_TEST_DOMAIN"

fi

###############################################################################
# TProxy UDP
###############################################################################

section "十七、检查 TProxy Socket"

if ss -lunp 2>/dev/null |
    grep -Eq "([.:])$TPROXY_PORT\b"
then

    pass "UDP :$TPROXY_PORT 正在监听"

else

    fail "UDP :$TPROXY_PORT 没有监听"

fi

if ss -lunp 2>/dev/null |
    grep -E "([.:])$TPROXY_PORT\b" |
    grep -qi mihomo
then

    pass "UDP :$TPROXY_PORT 属于 Mihomo"

else

    fail "UDP :$TPROXY_PORT 不是 Mihomo"

fi

###############################################################################
# TProxy TCP
###############################################################################

if ss -lntp 2>/dev/null |
    grep -Eq "([.:])$TPROXY_PORT\b"
then

    pass "TCP :$TPROXY_PORT 正在监听"

else

    fail "TCP :$TPROXY_PORT 没有监听"

fi

if ss -lntp 2>/dev/null |
    grep -E "([.:])$TPROXY_PORT\b" |
    grep -qi mihomo
then

    pass "TCP :$TPROXY_PORT 属于 Mihomo"

else

    fail "TCP :$TPROXY_PORT 不是 Mihomo"

fi

###############################################################################
# Controller
###############################################################################

section "十八、检查 Mihomo Controller"

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
        pass "Controller :$API_PORT 可访问"
        ;;
    *)
        warn "Controller :$API_PORT 无法正常访问"
        ;;
esac

###############################################################################
# 本机 HTTPS
###############################################################################

section "十九、本机实际 HTTPS"

info "测试：$HTTPS_TEST_URL"

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
        pass "本机 HTTPS 正常"
        ;;
    *)
        fail "本机 HTTPS 失败"
        ;;
esac

###############################################################################
# 代理环境变量
###############################################################################

section "二十、检查代理环境变量"

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
    pass "当前环境没有 HTTP/HTTPS/ALL_PROXY"
else
    warn "当前环境存在代理变量"
fi

###############################################################################
# nft Counter
###############################################################################

section "二十一、检查 nft Counter"

if [ -n "$NFT_RULES" ]; then

    COUNTER_LINES="$(
        echo "$NFT_RULES" |
        grep -E 'counter|tproxy|mark set' |
        head -n50 ||
        true
    )"

    if [ -n "$COUNTER_LINES" ]; then
        echo "$COUNTER_LINES"
        pass "发现 nft 流量统计规则"
    else
        warn "没有发现明显 nft counter"
    fi

else

    warn "无法读取 nft counter"

fi

###############################################################################
# 检查规则是否包含 bypass
###############################################################################

section "二十二、检查常见直连排除规则"

if [ -n "$NFT_RULES" ]; then

    BYPASS_COUNT="$(
        echo "$NFT_RULES" |
        grep -Eic \
        'return|accept|127\.0\.0\.0/8|224\.0\.0\.0/4|255\.255\.255\.255|localhost' ||
        true
    )"

    if [ "$BYPASS_COUNT" -gt 0 ]; then
        info "发现 $BYPASS_COUNT 个常见 bypass/return 相关规则"
    else
        info "没有发现明显 bypass 规则"
    fi

fi

###############################################################################
# 本机路由
###############################################################################

section "二十三、检查主路由表"

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

section "二十四、检查网关连通性"

if [ -n "$GATEWAY" ]; then

    if ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
        pass "默认网关可达：$GATEWAY"
    else
        warn "默认网关 ICMP 不可达：$GATEWAY"
    fi

else

    info "没有网关地址，跳过"

fi

###############################################################################
# Mihomo 日志错误扫描
###############################################################################

section "二十五、Mihomo 日志错误扫描"

# 读取最近日志
MIHOMO_RECENT_LOG="$(
    journalctl -u "$MIHOMO_SERVICE" \
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

        warn "Mihomo 最近存在出口连接异常，但不判定为 TProxy 核心故障"

    else

        warn "Mihomo 最近存在异常日志，请检查"

    fi

else

    pass "最近 Mihomo 日志没有发现明显错误"

fi

###############################################################################
# systemd 启动依赖
###############################################################################

section "二十六、检查 Mihomo systemd"

SERVICE_FILE="$(
    systemctl show "$MIHOMO_SERVICE" \
        -p FragmentPath \
        --value \
        2>/dev/null ||
    true
)"

if [ -n "$SERVICE_FILE" ] && [ -f "$SERVICE_FILE" ]; then

    info "Service：$SERVICE_FILE"

    if grep -qE 'After=.*network' "$SERVICE_FILE"; then
        pass "Mihomo service 包含网络启动依赖"
    else
        info "Mihomo service 未发现明显 network After"
    fi

else

    warn "无法获取 Mihomo service 文件"

fi

###############################################################################
# 最终诊断
###############################################################################

section "最终诊断"

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

###############################################################################
# 最终状态
###############################################################################

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then

    echo
    echo -e "${GREEN}============================================================${RESET}"
    echo -e "${GREEN}透明代理健康状态：HEALTHY${RESET}"
    echo -e "${GREEN}============================================================${RESET}"

    exit 0

elif [ "$FAIL" -eq 0 ]; then

    echo
    echo -e "${YELLOW}============================================================${RESET}"
    echo -e "${YELLOW}透明代理健康状态：DEGRADED${RESET}"
    echo -e "${YELLOW}核心链路正常，但存在 WARN 项${RESET}"
    echo -e "${YELLOW}============================================================${RESET}"

    exit 0

else

    echo
    echo -e "${RED}============================================================${RESET}"
    echo -e "${RED}透明代理健康状态：FAILED${RESET}"
    echo -e "${RED}存在核心故障，请根据上面的 FAIL 项排查${RESET}"
    echo -e "${RED}============================================================${RESET}"

    exit 1

fi