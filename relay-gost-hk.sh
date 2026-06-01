#!/usr/bin/env bash
set -euo pipefail

# 香港中转一键脚本 (gost 端口转发)
# 架构: 客户端 → 香港中转机(本脚本) → 台湾落地机 → 目标
# 出口仍是台湾, Cursor/AI 识别到的是台湾 IP
# 用法: sudo bash relay-gost-hk.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

GOST_VERSION="2.11.5"
GOST_BIN="/usr/local/bin/gost"
SERVICE_FILE="/etc/systemd/system/gost-relay.service"

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "请使用 root 用户运行: sudo bash $0"
    fi
}

install_deps() {
    info "安装依赖..."
    apt-get update -qq
    apt-get install -y -qq curl wget gzip > /dev/null 2>&1 || true
}

detect_arch() {
    local m
    m=$(uname -m)
    case "$m" in
        x86_64|amd64)   GOST_ARCH="amd64" ;;
        aarch64|arm64)  GOST_ARCH="armv8" ;;
        armv7l)         GOST_ARCH="armv7" ;;
        i386|i686)      GOST_ARCH="386" ;;
        *) error "暂不支持的架构: $m" ;;
    esac
}

install_gost() {
    if [[ -x "$GOST_BIN" ]]; then
        info "gost 已安装，跳过下载"
        return
    fi

    detect_arch
    local url="https://github.com/ginuerzh/gost/releases/download/v${GOST_VERSION}/gost-linux-${GOST_ARCH}-${GOST_VERSION}.gz"
    info "下载 gost (${GOST_ARCH})..."

    local tmp="/tmp/gost.gz"
    if ! wget -qO "$tmp" "$url"; then
        error "下载失败: $url"
    fi

    gunzip -f "$tmp"
    mv -f "/tmp/gost" "$GOST_BIN"
    chmod +x "$GOST_BIN"

    if [[ ! -x "$GOST_BIN" ]]; then
        error "gost 安装失败"
    fi
    info "gost 安装成功: $("$GOST_BIN" -V 2>&1 | head -1)"
}

read_inputs() {
    echo ""
    echo -e "${CYAN}── 配置中转参数 ──${NC}"
    echo ""

    while [[ -z "${TW_IP:-}" ]]; do
        read -rp "台湾落地机 IP/域名: " TW_IP
        if [[ -z "$TW_IP" ]]; then
            warn "不能为空"
        fi
    done

    read -rp "台湾落地机上的服务端口 [默认 443]: " TARGET_PORT
    TARGET_PORT=${TARGET_PORT:-443}

    read -rp "香港本机监听端口 [默认与上面相同 = ${TARGET_PORT}]: " LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-$TARGET_PORT}
}

test_target() {
    info "测试到台湾落地机 ${TW_IP}:${TARGET_PORT} 的连通性..."
    if timeout 6 bash -c "echo > /dev/tcp/${TW_IP}/${TARGET_PORT}" 2>/dev/null; then
        info "连通正常 ✓"
    else
        warn "无法连接 ${TW_IP}:${TARGET_PORT}（可能台湾机防火墙未放行该端口，或服务未启动）"
        warn "脚本将继续，但请确认台湾机已放行该端口"
    fi
}

enable_bbr() {
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc" == "bbr" ]]; then
        info "BBR 已启用"
        return
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
        cat >> /etc/sysctl.conf <<'SYSEOF'

# BBR
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSEOF
    fi
    sysctl -p > /dev/null 2>&1 || true
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [[ "$cc" == "bbr" ]]; then
        info "BBR 启用成功 ✓"
    else
        warn "BBR 未生效（内核可能不支持）"
    fi
}

write_service() {
    info "写入 systemd 服务..."
    local execcmd="${GOST_BIN} -L=tcp://:${LISTEN_PORT}/${TW_IP}:${TARGET_PORT} -L=udp://:${LISTEN_PORT}/${TW_IP}:${TARGET_PORT}"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=gost relay (HK -> TW)
After=network.target

[Service]
Type=simple
ExecStart=${execcmd}
Restart=on-failure
RestartSec=3
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    info "服务文件: $SERVICE_FILE"
}

setup_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "${LISTEN_PORT}"/tcp > /dev/null 2>&1 || true
        ufw allow "${LISTEN_PORT}"/udp > /dev/null 2>&1 || true
        info "UFW 已放行端口 ${LISTEN_PORT} (tcp/udp)"
    fi
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${LISTEN_PORT}"/tcp > /dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${LISTEN_PORT}"/udp > /dev/null 2>&1 || true
        firewall-cmd --reload > /dev/null 2>&1 || true
        info "firewalld 已放行端口 ${LISTEN_PORT}"
    fi
}

start_service() {
    info "启动中转服务..."
    systemctl daemon-reload
    systemctl enable gost-relay > /dev/null 2>&1
    systemctl restart gost-relay
    sleep 2
    if systemctl is-active --quiet gost-relay; then
        info "gost 中转运行中 ✓"
    else
        error "启动失败，请检查: journalctl -u gost-relay --no-pager -n 20"
    fi
}

get_hk_ip() {
    HK_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 ip.sb || echo "")
    if [[ -z "$HK_IP" ]]; then
        HK_IP="<你的香港机IP>"
    fi
}

print_result() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  香港中转部署完成${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  转发链路: ${GREEN}客户端 → ${HK_IP}:${LISTEN_PORT} → ${TW_IP}:${TARGET_PORT}${NC}"
    echo -e "  出口(目标看到的IP): ${GREEN}台湾 ${TW_IP}${NC}"
    echo ""
    echo -e "${CYAN}── 客户端怎么改 ──${NC}"
    echo ""
    echo -e "  在 v2rayN 里复制你现有的台湾节点, 只改一处:"
    echo -e "    地址(address): ${YELLOW}${TW_IP}  →  ${HK_IP}${NC}"
    echo -e "    端口(port):    ${YELLOW}${LISTEN_PORT}${NC}"
    echo -e "  其余全部不变: ${GREEN}UUID / 公钥pbk / shortId / SNI / flow / fp${NC}"
    echo ""
    echo -e "  ${YELLOW}注意: SNI 仍填台湾节点原来的伪装域名, 不要改成香港。${NC}"
    echo ""
    echo -e "${CYAN}── 管理命令 ──${NC}"
    echo ""
    echo "  状态:   systemctl status gost-relay"
    echo "  重启:   systemctl restart gost-relay"
    echo "  日志:   journalctl -u gost-relay -f"
    echo "  停止:   systemctl stop gost-relay && systemctl disable gost-relay"
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════${NC}"
}

main() {
    echo ""
    echo -e "${CYAN}  香港 gost 中转一键部署${NC}"
    echo ""

    check_root
    install_deps
    install_gost
    read_inputs
    test_target
    enable_bbr
    write_service
    setup_firewall
    start_service
    get_hk_ip
    print_result
}

main "$@"
