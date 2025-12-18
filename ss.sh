#!/bin/bash

# ==========================================
#             SS-Argo 一键脚本
# ==========================================

WORK_DIR="/root/ss-argo"
VARS_FILE="$WORK_DIR/vars.conf"
CONFIG_FILE="$WORK_DIR/config.json"
LOG_FILE="/var/log/ss-argo.log"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 检查 Root
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 运行${NC}"; exit 1; fi

# 判断系统初始化系统 (Systemd vs OpenRC)
check_init_system() {
    if [ -f /etc/alpine-release ]; then
        INIT_SYS="openrc"
    elif command -v systemctl &>/dev/null; then
        INIT_SYS="systemd"
    else
        INIT_SYS="unknown"
    fi
}

install_deps() {
    if ! command -v wget &>/dev/null || ! command -v unzip &>/dev/null || ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}安装必要工具...${NC}"
        if [ -f /etc/alpine-release ]; then
            apk update && apk add wget curl unzip bash openrc
        elif [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y wget curl unzip
        elif [ -f /etc/redhat-release ]; then
            yum install -y wget curl unzip
        elif [ -f /etc/arch-release ]; then
            pacman -Sy --noconfirm wget curl unzip
        fi
    fi
}

download_core() {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit
    ARCH=$(uname -m)
    XRAY_VER="v1.8.4" 
    
    if [[ "$ARCH" == "x86_64" ]]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"
        ARGO_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        XRAY_URL="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-arm64-v8a.zip"
        ARGO_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64"
    else
        echo -e "${RED}不支持的架构: $ARCH${NC}"; exit 1
    fi

    if [ ! -f "web" ]; then
        echo -e "${YELLOW}下载 Xray...${NC}"
        wget -qO xray.zip "$XRAY_URL" && unzip -q xray.zip "xray" && mv xray web && rm -f xray.zip && chmod +x web
    fi
    if [ ! -f "bot" ]; then
        echo -e "${YELLOW}下载 Argo...${NC}"
        wget -qO bot "$ARGO_URL" && chmod +x bot
    fi
}

apply_config() {
    cat > "$VARS_FILE" <<EOF
UUID=$UUID
TOKEN=$TOKEN
DOMAIN=$DOMAIN
PORT=$PORT
EOF

    cat > "$CONFIG_FILE" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": $PORT,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": "$UUID",
        "network": "tcp,udp"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/ss-argo" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "tag": "direct" }, { "protocol": "blackhole", "tag": "block" } ]
}
EOF
}

get_input_and_install() {
    read -p "请输入 UUID (回车随机): " IN_UUID
    [ -z "$IN_UUID" ] && IN_UUID=$(cat /proc/sys/kernel/random/uuid)
    read -p "请输入 Argo Token (必填): " IN_TOKEN
    read -p "请输入 Argo 域名 (必填): " IN_DOMAIN
    read -p "请输入 Argo 端口 (默认 8001): " IN_PORT
    [ -z "$IN_PORT" ] && IN_PORT="8001"

    if [ -z "$IN_TOKEN" ] || [ -z "$IN_DOMAIN" ]; then echo -e "${RED}必填项不能为空${NC}"; exit 1; fi

    UUID=$IN_UUID
    TOKEN=$IN_TOKEN
    DOMAIN=$IN_DOMAIN
    PORT=$IN_PORT
    
    apply_config
}

setup_service() {
    # 创建统一的启动脚本 (Start Wrapper)
    # Alpine 需要日志重定向到文件，因为没有 journalctl
    cat > "$WORK_DIR/start.sh" <<EOF
#!/bin/bash
cd $WORK_DIR
# 清理旧进程
pkill -f "$WORK_DIR/web"
pkill -f "$WORK_DIR/bot"

# 启动 Xray (后台)
nohup ./web -c config.json >/dev/null 2>&1 &

# 启动 Argo (前台运行，以便服务管理器监控，日志输出到文件)
TOKEN=\$(grep TOKEN vars.conf | cut -d= -f2)
./bot tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token \$TOKEN >> $LOG_FILE 2>&1
EOF
    chmod +x "$WORK_DIR/start.sh"

    check_init_system

    if [ "$INIT_SYS" == "openrc" ]; then
        # --- Alpine OpenRC 配置 ---
        echo -e "${YELLOW}检测到 OpenRC (Alpine)，正在配置服务...${NC}"
        cat > /etc/init.d/ss-argo <<EOF
#!/sbin/openrc-run

name="ss-argo"
command="$WORK_DIR/start.sh"
command_background=true
pidfile="/run/ss-argo.pid"
output_log="$LOG_FILE"
error_log="$LOG_FILE"

depend() {
    need net
    after firewall
}
EOF
        chmod +x /etc/init.d/ss-argo
        rc-update add ss-argo default >/dev/null 2>&1
        rc-service ss-argo restart

    elif [ "$INIT_SYS" == "systemd" ]; then
        # --- Systemd 配置 ---
        echo -e "${YELLOW}检测到 Systemd，正在配置服务...${NC}"
        cat > /etc/systemd/system/ss-argo.service <<EOF
[Unit]
Description=SS-Argo Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$WORK_DIR/start.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ss-argo >/dev/null 2>&1
        systemctl restart ss-argo
    else
        echo -e "${RED}未知的初始化系统，无法自动配置服务启动。请手动运行 $WORK_DIR/start.sh${NC}"
    fi
}

manage_service() {
    local action=$1
    check_init_system
    if [ "$INIT_SYS" == "openrc" ]; then
        rc-service ss-argo $action
    elif [ "$INIT_SYS" == "systemd" ]; then
        systemctl $action ss-argo
    fi
}

check_service_status() {
    check_init_system
    if [ "$INIT_SYS" == "openrc" ]; then
        rc-service ss-argo status | grep -q "started" && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"
    elif [ "$INIT_SYS" == "systemd" ]; then
        systemctl is-active ss-argo &>/dev/null && echo -e "${GREEN}运行中${NC}" || echo -e "${RED}未运行${NC}"
    fi
}

modify_config() {
    if [ ! -f "$VARS_FILE" ]; then echo -e "${RED}尚未安装。${NC}"; return; fi
    source "$VARS_FILE"
    
    echo -e "当前: UUID=${SKYBLUE}${UUID}${NC} | 端口=${SKYBLUE}${PORT}${NC} | 域名=${SKYBLUE}${DOMAIN}${NC}"
    echo "1. Token"
    echo "2. 域名"
    echo "3. 端口"
    read -p "选择: " m
    case $m in
        1) read -p "新Token: " v; [ ! -z "$v" ] && TOKEN="$v" ;;
        2) read -p "新域名: " v; [ ! -z "$v" ] && DOMAIN="$v" ;;
        3) read -p "新端口: " v; [ ! -z "$v" ] && PORT="$v" ;;
        *) return ;;
    esac

    echo -e "${YELLOW}更新配置...${NC}"
    apply_config
    manage_service restart
    sleep 2
    show_link
}

show_link() {
    if [ ! -f "$VARS_FILE" ]; then echo "无配置"; return; fi
    source "$VARS_FILE"
    
    CF_IP="cdns.doon.eu.org"
    USER_INFO=$(echo -n "chacha20-ietf-poly1305:${UUID}" | base64 | tr -d '\n')
    PLUGIN_OPTS="v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3D${DOMAIN}%3Bpath%3D%2Fss-argo%3Btls%3Bsni%3D${DOMAIN}"
    LINK="ss://${USER_INFO}@${CF_IP}:443?plugin=${PLUGIN_OPTS}#ARGO-SS"

    echo -e "${GREEN}================ 节点信息 =================${NC}"
    echo -n "服务状态: "; check_service_status
    echo -e "${YELLOW}SS 链接:${NC}"
    echo "$LINK"
    echo -e "${GREEN}===========================================${NC}"
}

show_log() {
    check_init_system
    echo -e "${YELLOW}正在查看日志 (Ctrl+C 退出)...${NC}"
    if [ "$INIT_SYS" == "openrc" ]; then
        tail -f "$LOG_FILE"
    else
        journalctl -u ss-argo -f -n 50
    fi
}

install_app() {
    install_deps
    manage_service stop 2>/dev/null
    download_core
    get_input_and_install
    setup_service
    sleep 3
    show_link
}

uninstall_app() {
    manage_service stop
    check_init_system
    if [ "$INIT_SYS" == "openrc" ]; then
        rc-update del ss-argo
        rm -f /etc/init.d/ss-argo
    else
        systemctl disable ss-argo
        rm -f /etc/systemd/system/ss-argo.service
        systemctl daemon-reload
    fi
    rm -rf "$WORK_DIR" "/usr/bin/ss" "$LOG_FILE"
    echo -e "${GREEN}已卸载。${NC}"
}

create_shortcut() {
    cat > /usr/bin/ss <<EOF
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/kele35818/ss-argo/refs/heads/main/ss.sh)
EOF
    chmod +x /usr/bin/ss
}

# === 菜单 ===
clear
echo -e "${SKYBLUE}=== SS-Argo 管理 ===${NC}"
echo -n "状态: "; check_service_status
echo "1. 安装 / 重装"
echo "2. 卸载"
echo "3. 修改配置"
echo "4. 查看链接"
echo "5. 查看日志"
echo "0. 退出"
read -p "选择: " choice

case $choice in
    1) install_app; create_shortcut ;;
    2) uninstall_app ;;
    3) modify_config ;;
    4) show_link ;;
    5) show_log ;;
    0) exit 0 ;;
    *) echo "无效" ;;
esac
