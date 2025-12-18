#!/bin/bash

# ==========================================
#             SS-Argo 一键脚本 
# ==========================================

WORK_DIR="/root/ss-argo"
SERVICE_FILE="/etc/systemd/system/ss-argo.service"
VARS_FILE="$WORK_DIR/vars.conf"
CONFIG_FILE="$WORK_DIR/config.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 检查 Root
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 运行${NC}"; exit 1; fi

install_deps() {
    if ! command -v wget &>/dev/null || ! command -v unzip &>/dev/null || ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}安装必要工具...${NC}"
        if [ -f /etc/alpine-release ]; then
            apk update && apk add wget curl unzip bash
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

# --- 核心逻辑：将变量写入配置文件 ---
apply_config() {
    # 1. 保存变量到文件 (持久化)
    cat > "$VARS_FILE" <<EOF
UUID=$UUID
TOKEN=$TOKEN
DOMAIN=$DOMAIN
PORT=$PORT
EOF

    # 2. 生成 Xray Config (使用当前变量)
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

# 初始安装时获取输入
get_input_and_install() {
    read -p "请输入 UUID (回车随机): " IN_UUID
    [ -z "$IN_UUID" ] && IN_UUID=$(cat /proc/sys/kernel/random/uuid)
    read -p "请输入 Argo Token (必填): " IN_TOKEN
    read -p "请输入 Argo 域名 (必填): " IN_DOMAIN
    read -p "请输入 Argo 端口 (默认 8001): " IN_PORT
    [ -z "$IN_PORT" ] && IN_PORT="8001"

    if [ -z "$IN_TOKEN" ] || [ -z "$IN_DOMAIN" ]; then echo -e "${RED}必填项不能为空${NC}"; exit 1; fi

    # 赋值给全局变量
    UUID=$IN_UUID
    TOKEN=$IN_TOKEN
    DOMAIN=$IN_DOMAIN
    PORT=$IN_PORT
    
    # 应用配置
    apply_config
}

setup_service() {
    # 启动脚本：动态读取 TOKEN，确保修改 Token 后重启即生效
    cat > "$WORK_DIR/start.sh" <<EOF
#!/bin/bash
cd $WORK_DIR
# 启动 Xray
nohup ./web -c config.json >/dev/null 2>&1 &
# 启动 Argo (从 vars.conf 读取 TOKEN)
TOKEN=\$(grep TOKEN vars.conf | cut -d= -f2)
./bot tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token \$TOKEN
EOF
    chmod +x "$WORK_DIR/start.sh"

    cat > "$SERVICE_FILE" <<EOF
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
}

# --- 修改配置功能 ---
modify_config() {
    if [ ! -f "$VARS_FILE" ]; then echo -e "${RED}尚未安装，请先安装。${NC}"; return; fi
    
    # 读取当前配置
    source "$VARS_FILE"
    
    echo -e "当前配置: UUID=${SKYBLUE}${UUID}${NC} | 端口=${SKYBLUE}${PORT}${NC} | 域名=${SKYBLUE}${DOMAIN}${NC}"
    echo "1. 修改 Token"
    echo "2. 修改 域名"
    echo "3. 修改 端口"
    read -p "请选择修改项 [1-3]: " mod_choice

    case $mod_choice in
        1) read -p "请输入新 Token: " NEW_VAL; [ ! -z "$NEW_VAL" ] && TOKEN="$NEW_VAL" ;;
        2) read -p "请输入新 域名: " NEW_VAL; [ ! -z "$NEW_VAL" ] && DOMAIN="$NEW_VAL" ;;
        3) read -p "请输入新 端口: " NEW_VAL; [ ! -z "$NEW_VAL" ] && PORT="$NEW_VAL" ;;
        *) echo "取消修改"; return ;;
    esac

    echo -e "${YELLOW}正在更新配置文件并重启服务...${NC}"
    apply_config  # 重新写入文件
    systemctl restart ss-argo # 重启生效
    
    sleep 2
    echo -e "${GREEN}修改成功！${NC}"
    show_link
}

show_link() {
    if [ ! -f "$VARS_FILE" ]; then echo "未找到配置文件"; return; fi
    source "$VARS_FILE"
    
    CF_IP="cdns.doon.eu.org"
    USER_INFO=$(echo -n "chacha20-ietf-poly1305:${UUID}" | base64 | tr -d '\n')
    PLUGIN_OPTS="v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3D${DOMAIN}%3Bpath%3D%2Fss-argo%3Btls%3Bsni%3D${DOMAIN}"
    LINK="ss://${USER_INFO}@${CF_IP}:443?plugin=${PLUGIN_OPTS}#argo-SS"

    echo -e "${GREEN}================ 节点信息 =================${NC}"
    echo -e "服务状态: $(systemctl is-active ss-argo)"
    echo -e "${YELLOW}SS 链接:${NC}"
    echo "$LINK"
    echo -e "${GREEN}===========================================${NC}"
}

install_app() {
    install_deps
    systemctl stop ss-argo 2>/dev/null
    download_core
    get_input_and_install
    setup_service
    sleep 3
    show_link
}

uninstall_app() {
    systemctl stop ss-argo
    systemctl disable ss-argo
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$WORK_DIR"
    rm -f "/usr/bin/ss"
    echo -e "${GREEN}已彻底卸载。${NC}"
}

create_shortcut() {
    cat > /usr/bin/ss <<EOF
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/guoziyou/my-proxy/main/ss.sh)
EOF
    chmod +x /usr/bin/ss
}

# === 主菜单 ===
clear
echo -e "${SKYBLUE}=== SS-Argo 管理脚本 ===${NC}"
if systemctl is-active ss-argo &>/dev/null; then
    echo -e "状态: ${GREEN}运行中${NC}"
else
    echo -e "状态: ${RED}未运行${NC}"
fi
echo "1. 安装 / 重装"
echo "2. 卸载"
echo "3. 修改配置 (Token / 域名 / 端口)"
echo "4. 查看链接"
echo "5. 查看日志 (按 Ctrl+C 退出)"
echo "0. 退出"
read -p "选择: " choice

case $choice in
    1) install_app; create_shortcut ;;
    2) uninstall_app ;;
    3) modify_config ;;
    4) show_link ;;
    5) journalctl -u ss-argo -f -n 50 ;;
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
