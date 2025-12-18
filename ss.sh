#!/bin/bash

# ==========================================
#             SS-Argo 一键脚本 
# ==========================================

WORK_DIR="/root/ss-argo"
SERVICE_FILE="/etc/systemd/system/ss-argo.service"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 检查 Root
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 运行${NC}"; exit 1; fi

# 安装必要工具
install_deps() {
    if ! command -v wget &>/dev/null || ! command -v unzip &>/dev/null || ! command -v curl &>/dev/null; then
        echo -e "${YELLOW}安装必要工具 (wget, curl, unzip)...${NC}"
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

# 1. 下载核心文件 (自动识别架构)
download_core() {
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit

    ARCH=$(uname -m)
    echo -e "${YELLOW}检测系统架构: $ARCH${NC}"

    # --- 下载 Xray ---
    XRAY_VER="v1.8.4" # 这里的版本可以按需更新
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
        echo -e "${YELLOW}正在下载 Xray...${NC}"
        wget -qO xray.zip "$XRAY_URL"
        unzip -q xray.zip "xray"
        mv xray web
        rm -f xray.zip
        chmod +x web
    fi

    if [ ! -f "bot" ]; then
        echo -e "${YELLOW}正在下载 Argo (Cloudflared)...${NC}"
        wget -qO bot "$ARGO_URL"
        chmod +x bot
    fi
}

# 2. 生成配置
generate_config() {
    # 输入参数
    read -p "请输入 UUID (回车随机): " IN_UUID
    [ -z "$IN_UUID" ] && IN_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    read -p "请输入 Argo Token (必填): " IN_TOKEN
    
    read -p "请输入 Argo 域名 (必填): " IN_DOMAIN
    
    read -p "请输入 内部端口 (默认 8001): " IN_PORT
    [ -z "$IN_PORT" ] && IN_PORT="8001"

    if [ -z "$IN_TOKEN" ] || [ -z "$IN_DOMAIN" ]; then
        echo -e "${RED}Token 和 域名必填！${NC}"; exit 1
    fi

    # 保存配置变量到文件，方便后续查看
    cat > "$WORK_DIR/vars.conf" <<EOF
UUID=$IN_UUID
TOKEN=$IN_TOKEN
DOMAIN=$IN_DOMAIN
PORT=$IN_PORT
EOF

    # 生成 Xray Config
    cat > "$WORK_DIR/config.json" <<EOF
{
  "log": { "loglevel": "none" },
  "inbounds": [
    {
      "port": $IN_PORT,
      "listen": "127.0.0.1",
      "protocol": "shadowsocks",
      "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": "$IN_UUID",
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

# 3. 创建 Systemd 服务 (替代 PM2)
setup_service() {
    # 创建一个启动包装脚本，确保同时启动 xray 和 argo
    cat > "$WORK_DIR/start.sh" <<EOF
#!/bin/bash
cd $WORK_DIR
# 启动 Xray
nohup ./web -c config.json >/dev/null 2>&1 &
# 启动 Argo
./bot tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token \$(grep TOKEN vars.conf | cut -d= -f2)
EOF
    chmod +x "$WORK_DIR/start.sh"

    # 创建 systemd 文件
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

    # 重载并启动
    systemctl daemon-reload
    systemctl enable ss-argo >/dev/null 2>&1
    systemctl restart ss-argo
}

# 4. 生成链接
show_link() {
    # 读取配置
    source "$WORK_DIR/vars.conf" 2>/dev/null
    
    # 构造 SS 链接
    # ss://Base64(method:password)@ip:port?plugin=...
    # 注意：Cloudflare CDN IP 可以用 www.visa.com.sg 等优选 IP，这里用默认
    CF_IP="cdns.doon.eu.org"
    USER_INFO=$(echo -n "chacha20-ietf-poly1305:${UUID}" | base64 | tr -d '\n')
    
    # URL Encode plugin 参数
    # v2ray-plugin;mode=websocket;host=DOMAIN;path=/ss-argo;tls;sni=DOMAIN
    # 手动转义: ; -> %3B, = -> %3D, / -> %2F
    PLUGIN_OPTS="v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3D${DOMAIN}%3Bpath%3D%2Fss-argo%3Btls%3Bsni%3D${DOMAIN}"
    
    LINK="ss://${USER_INFO}@${CF_IP}:443?plugin=${PLUGIN_OPTS}#${DOMAIN}-SS"

    echo -e "${GREEN}================ 节点部署成功！=================${NC}"
    echo -e "状态: $(systemctl is-active ss-argo)"
    echo -e "${YELLOW}SS 链接:${NC}"
    echo "$LINK"
    echo -e "${GREEN}===============================================${NC}"
}

# 菜单函数
install_app() {
    install_deps
    # 停止旧服务
    systemctl stop ss-argo 2>/dev/null
    
    download_core
    generate_config
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

# 创建快捷指令
create_shortcut() {
    cat > /usr/bin/ss <<EOF
#!/bin/bash
bash <(curl -Ls https://raw.githubusercontent.com/guoziyou/my-proxy/main/ss.sh)
EOF
    chmod +x /usr/bin/ss
}

# === 主逻辑 ===
clear
echo -e "${SKYBLUE}===  SS-Argo 一键脚本 ===${NC}"
echo "1. 安装 / 重装"
echo "2. 卸载"
echo "3. 查看链接"
echo "4. 查看日志"
echo "0. 退出"
read -p "选择: " choice

case $choice in
    1) install_app; create_shortcut ;;
    2) uninstall_app ;;
    3) show_link ;;
    4) journalctl -u ss-argo -f -n 20 ;; # 查看 systemd 日志
    0) exit 0 ;;
    *) echo "无效选择" ;;
esac
