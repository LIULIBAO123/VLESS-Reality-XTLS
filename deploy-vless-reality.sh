#!/usr/bin/env bash
set -euo pipefail

# VLESS + Reality + XTLS Vision 一键部署脚本 (Ubuntu)
# 用法: bash deploy-vless-reality.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

XRAY_DIR="/usr/local/etc/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    [[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本: sudo bash $0"
}

check_os() {
    if ! grep -qi 'ubuntu\|debian' /etc/os-release 2>/dev/null; then
        warn "此脚本为 Ubuntu/Debian 设计，其他系统可能不兼容"
    fi
}

install_deps() {
    info "安装依赖..."
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq openssl > /dev/null 2>&1
}

install_xray() {
    if command -v xray &>/dev/null; then
        local ver
        ver=$(xray version 2>/dev/null | head -1 | awk '{print $2}')
        info "Xray 已安装 (${ver})，跳过安装"
        return
    fi

    info "安装 Xray-core..."
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

    command -v xray &>/dev/null || error "Xray 安装失败"
    info "Xray 安装成功: $(xray version | head -1)"
}

generate_keys() {
    info "生成密钥对..."
    KEY_OUTPUT=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | grep 'Private' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | grep 'Public' | awk '{print $NF}')

    [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && error "密钥生成失败"
}

generate_uuid() {
    UUID=$(xray uuid)
    [[ -z "$UUID" ]] && UUID=$(cat /proc/sys/kernel/random/uuid)
}

generate_short_id() {
    SHORT_ID=$(openssl rand -hex 8)
}

get_server_ip() {
    SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 ip.sb || echo "")
    [[ -z "$SERVER_IP" ]] && error "无法获取服务器公网 IP"
}

select_dest() {
    echo ""
    echo -e "${CYAN}选择 Reality 伪装目标（dest）:${NC}"
    echo "  1) www.microsoft.com        (推荐，全球稳定)"
    echo "  2) www.apple.com"
    echo "  3) gateway.icloud.com"
    echo "  4) www.samsung.com"
    echo "  5) 自定义"
    echo ""

    local choice
    read -rp "请选择 [1-5，默认 1]: " choice
    choice=${choice:-1}

    case $choice in
        1) DEST="www.microsoft.com:443"; SERVER_NAME="www.microsoft.com" ;;
        2) DEST="www.apple.com:443"; SERVER_NAME="www.apple.com" ;;
        3) DEST="gateway.icloud.com:443"; SERVER_NAME="gateway.icloud.com" ;;
        4) DEST="www.samsung.com:443"; SERVER_NAME="www.samsung.com" ;;
        5)
            read -rp "请输入伪装域名 (如 example.com): " custom_dest
            DEST="${custom_dest}:443"
            SERVER_NAME="$custom_dest"
            ;;
        *) DEST="www.microsoft.com:443"; SERVER_NAME="www.microsoft.com" ;;
    esac
}

select_port() {
    echo ""
    read -rp "请输入监听端口 [默认 443]: " input_port
    PORT=${input_port:-443}

    if ss -tlnp | grep -q ":${PORT} "; then
        warn "端口 ${PORT} 已被占用:"
        ss -tlnp | grep ":${PORT} "
        read -rp "是否继续? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && error "已取消"
    fi
}

write_config() {
    info "生成配置文件..."
    mkdir -p "$XRAY_DIR"

    cat > "$XRAY_CONFIG" <<XEOF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": ${PORT},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${DEST}",
                    "xver": 0,
                    "serverNames": [
                        "${SERVER_NAME}"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "shortIds": [
                        "${SHORT_ID}",
                        ""
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
XEOF

    info "配置文件写入: $XRAY_CONFIG"
}

enable_bbr() {
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")

    if [[ "$current_cc" == "bbr" ]]; then
        info "BBR 已启用，跳过"
        return
    fi

    info "启用 BBR 拥塞控制..."

    local kver
    kver=$(uname -r | cut -d. -f1-2)
    if awk "BEGIN {exit !($kver < 4.9)}"; then
        warn "内核版本 $(uname -r) < 4.9，不支持 BBR，跳过"
        return
    fi

    cat >> /etc/sysctl.conf <<'SYSEOF'

# BBR congestion control
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSEOF

    sysctl -p > /dev/null 2>&1

    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ "$current_cc" == "bbr" ]]; then
        info "BBR 启用成功 ✓"
    else
        warn "BBR 启用失败，当前拥塞算法: $current_cc"
    fi
}

optimize_sysctl() {
    info "优化内核网络参数..."

    if grep -q "# Xray network optimization" /etc/sysctl.conf 2>/dev/null; then
        info "网络优化参数已存在，跳过"
        return
    fi

    cat >> /etc/sysctl.conf <<'SYSEOF'

# Xray network optimization
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_max_syn_backlog=8192
net.core.somaxconn=32768
net.core.netdev_max_backlog=16384
SYSEOF

    sysctl -p > /dev/null 2>&1
    info "网络参数优化完成 ✓"
}

setup_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "$PORT"/tcp > /dev/null 2>&1 && info "UFW 已放行端口 $PORT"
    fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="$PORT"/tcp > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
        info "firewalld 已放行端口 $PORT"
    fi
}

start_xray() {
    info "启动 Xray..."
    systemctl daemon-reload
    systemctl enable xray > /dev/null 2>&1
    systemctl restart xray

    sleep 2
    if systemctl is-active --quiet xray; then
        info "Xray 运行中 ✓"
    else
        error "Xray 启动失败，请检查: journalctl -u xray --no-pager -n 20"
    fi
}

generate_client_link() {
    local params="security=reality&encryption=none&flow=xtls-rprx-vision"
    params+="&type=tcp&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}"

    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?${params}#VLESS-Reality"
}

print_result() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  VLESS + Reality + XTLS Vision 部署完成${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  协议:       ${GREEN}VLESS${NC}"
    echo -e "  地址:       ${GREEN}${SERVER_IP}${NC}"
    echo -e "  端口:       ${GREEN}${PORT}${NC}"
    echo -e "  UUID:       ${GREEN}${UUID}${NC}"
    echo -e "  流控:       ${GREEN}xtls-rprx-vision${NC}"
    echo -e "  传输:       ${GREEN}tcp${NC}"
    echo -e "  安全:       ${GREEN}reality${NC}"
    echo -e "  SNI:        ${GREEN}${SERVER_NAME}${NC}"
    echo -e "  指纹:       ${GREEN}chrome${NC}"
    echo -e "  公钥:       ${GREEN}${PUBLIC_KEY}${NC}"
    echo -e "  Short ID:   ${GREEN}${SHORT_ID}${NC}"
    echo ""
    echo -e "${CYAN}── 分享链接（可直接导入客户端）──${NC}"
    echo ""
    echo -e "  ${YELLOW}${VLESS_LINK}${NC}"
    echo ""
    echo -e "${CYAN}── 管理命令 ──${NC}"
    echo ""
    echo "  状态:   systemctl status xray"
    echo "  重启:   systemctl restart xray"
    echo "  日志:   journalctl -u xray -f"
    echo "  配置:   $XRAY_CONFIG"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
}

save_info() {
    local info_file="$XRAY_DIR/client-info.txt"
    cat > "$info_file" <<EOF
VLESS + Reality 客户端信息
==========================
地址: ${SERVER_IP}
端口: ${PORT}
UUID: ${UUID}
流控: xtls-rprx-vision
传输: tcp
安全: reality
SNI:  ${SERVER_NAME}
公钥: ${PUBLIC_KEY}
Short ID: ${SHORT_ID}

分享链接:
${VLESS_LINK}
EOF
    info "客户端信息已保存至: $info_file"
}

main() {
    echo ""
    echo -e "${CYAN}  VLESS + Reality + XTLS Vision 一键部署${NC}"
    echo ""

    check_root
    check_os
    install_deps
    install_xray
    generate_keys
    generate_uuid
    generate_short_id
    get_server_ip
    select_dest
    select_port
    write_config
    enable_bbr
    optimize_sysctl
    setup_firewall
    start_xray
    generate_client_link
    print_result
    save_info
}

main "$@"
