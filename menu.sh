#!/bin/bash

# 全局配置
# 请确保这里替换为你自己的 GitHub 仓库地址
REPO_URL="https://github.com/kele35818/ss-argo.git"
APP_DIR="/root/ss-argo"
SCRIPT_PATH="$APP_DIR/menu.sh"

# --- 修改点：将快捷指令名称改为 ss ---
SHORTCUT_NAME="ss" 

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

# 检查 Root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 用户运行此脚本${NC}"
        exit 1
    fi
}

# 创建快捷指令
create_shortcut() {
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH"
        ln -sf "$SCRIPT_PATH" "/usr/bin/$SHORTCUT_NAME"
        echo -e "${GREEN}快捷指令 '$SHORTCUT_NAME' 已创建，以后只需输入 $SHORTCUT_NAME 即可打开此菜单。${NC}"
    fi
}

# 获取当前 PM2 环境变量 (用于修改配置时保留旧值)
get_current_env() {
    if pm2 describe node-proxy >/dev/null 2>&1; then
        CUR_UUID=$(pm2 describe node-proxy | grep "UUID" | awk '{print $4}' | tr -d "'" | tr -d '"')
        CUR_TOKEN=$(pm2 describe node-proxy | grep "ARGO_AUTH" | awk '{print $4}' | tr -d "'" | tr -d '"')
        CUR_DOMAIN=$(pm2 describe node-proxy | grep "ARGO_DOMAIN" | awk '{print $4}' | tr -d "'" | tr -d '"')
    else
        CUR_UUID=""
        CUR_TOKEN=""
        CUR_DOMAIN=""
    fi
}

# 1. 安装服务
install_app() {
    echo -e "${YELLOW}=== 开始安装 ===${NC}"
    
    # 环境检查
    if ! command -v node &> /dev/null; then
        echo "安装 Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
        apt-get install -y nodejs git >/dev/null 2>&1 || yum install -y nodejs git >/dev/null 2>&1
    fi
    if ! command -v pm2 &> /dev/null; then npm install -g pm2 >/dev/null 2>&1; fi

    # 拉取代码
    rm -rf "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR" || exit
    npm install

    # 获取输入
    read -p "请输入 UUID (回车随机): " IN_UUID
    read -p "请输入 Argo Token (必填): " IN_TOKEN
    read -p "请输入 Argo 域名 (必填): " IN_DOMAIN

    if [ -z "$IN_TOKEN" ] || [ -z "$IN_DOMAIN" ]; then
        echo -e "${RED}Token 和 域名不能为空！${NC}"
        return
    fi

    # 启动
    ENV_STR="ARGO_AUTH='$IN_TOKEN' ARGO_DOMAIN='$IN_DOMAIN'"
    if [ ! -z "$IN_UUID" ]; then ENV_STR="$ENV_STR UUID='$IN_UUID'"; fi
    
    pm2 delete node-proxy >/dev/null 2>&1
    eval "$ENV_STR pm2 start main.js --name node-proxy"
    pm2 save >/dev/null 2>&1
    pm2 startup | bash >/dev/null 2>&1
    
    create_shortcut
    echo -e "${GREEN}安装完成！${NC}"
    show_info
}

# 2. 卸载服务
uninstall_app() {
    read -p "确定要卸载吗？(y/n): " confirm
    if [ "$confirm" == "y" ]; then
        pm2 delete node-proxy >/dev/null 2>&1
        pm2 save >/dev/null 2>&1
        rm -rf "$APP_DIR"
        rm -f "/usr/bin/$SHORTCUT_NAME"
        echo -e "${GREEN}已彻底卸载。${NC}"
    else
        echo "取消操作。"
    fi
}

# 3. 修改配置 (通用函数)
update_config() {
    get_current_env # 获取当前值
    if [ -z "$CUR_TOKEN" ]; then
        echo -e "${RED}服务未运行，无法修改。请先安装。${NC}"
        return
    fi

    echo -e "当前配置:"
    echo -e "UUID: ${SKYBLUE}$CUR_UUID${NC}"
    echo -e "域名: ${SKYBLUE}$CUR_DOMAIN${NC}"
    
    local TYPE=$1
    local NEW_TOKEN="$CUR_TOKEN"
    local NEW_DOMAIN="$CUR_DOMAIN"

    if [ "$TYPE" == "token" ]; then
        read -p "请输入新的 Argo Token: " NEW_TOKEN
    elif [ "$TYPE" == "domain" ]; then
        read -p "请输入新的 Argo 域名: " NEW_DOMAIN
    fi

    if [ -z "$NEW_TOKEN" ] || [ -z "$NEW_DOMAIN" ]; then
        echo -e "${RED}输入不能为空！${NC}"
        return
    fi

    echo -e "${YELLOW}正在更新配置...${NC}"
    pm2 delete node-proxy >/dev/null 2>&1
    eval "ARGO_AUTH='$NEW_TOKEN' ARGO_DOMAIN='$NEW_DOMAIN' UUID='$CUR_UUID' pm2 start main.js --name node-proxy"
    pm2 save >/dev/null 2>&1
    
    echo -e "${GREEN}修改成功！正在重启服务...${NC}"
    sleep 3
    show_info
}

# 4. 查看节点信息
show_info() {
    echo -e "${YELLOW}正在获取节点信息...${NC}"
    # 尝试从日志中抓取
    if pm2 logs node-proxy --lines 50 --nostream | grep -q "SS 链接"; then
        echo -e "${GREEN}================ 节点信息 =================${NC}"
        pm2 logs node-proxy --lines 50 --nostream | grep -A 5 "\[SS 链接\]"
        echo -e "${GREEN}===========================================${NC}"
    else
        echo -e "${RED}日志中未找到链接，请等待几秒后重试，或检查服务是否正常运行。${NC}"
        echo -e "尝试命令: pm2 logs node-proxy"
    fi
}

# === 主菜单 ===
show_menu() {
    clear
    echo -e "${SKYBLUE}#############################################${NC}"
    echo -e "${SKYBLUE}#          SS-ARGO 代理管理脚本             #${NC}"
    echo -e "${SKYBLUE}#          快捷命令: $SHORTCUT_NAME                     #${NC}"
    echo -e "${SKYBLUE}#############################################${NC}"
    
    # 检查运行状态
    if pm2 list | grep -q "node-proxy"; then
        STATUS="${GREEN}运行中${NC}"
    else
        STATUS="${RED}未运行${NC}"
    fi
    echo -e "当前状态: $STATUS"
    echo ""
    echo -e "1. 安装/重装 ss-argo"
    echo -e "2. 卸载 ss-argo"
    echo -e "3. 修改 Argo 隧道配置"
    echo -e "4. 查看节点链接"
    echo -e "0. 退出"
    echo ""
    read -p "请选择 [0-4]: " choice

    case $choice in
        1) install_app ;;
        2) uninstall_app ;;
        3) 
            echo ""
            echo -e "   1. 修改 Argo Token"
            echo -e "   2. 修改 Argo 域名"
            read -p "   请选择 [1-2]: " sub_choice
            case $sub_choice in
                1) update_config "token" ;;
                2) update_config "domain" ;;
                *) echo "无效选择" ;;
            esac
            ;;
        4) show_info ;;
        0) exit 0 ;;
        *) echo "无效选择" ;;
    esac
    
    if [ "$choice" != "0" ]; then
        echo ""
        read -p "按回车键返回主菜单..."
        show_menu
    fi
}

check_root
# 如果是第一次运行（非快捷方式），尝试建立快捷方式
if [ "$0" != "/usr/bin/$SHORTCUT_NAME" ]; then
    create_shortcut >/dev/null 2>&1
fi

show_menu
