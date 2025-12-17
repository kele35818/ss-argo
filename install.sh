#!/bin/bash

# 全局配置
REPO_URL="https://github.com/kele35818/ss-argo.git"
APP_DIR="/root/ss-argo"
SCRIPT_PATH="$APP_DIR/menu.sh"
SHORTCUT_NAME="ss" 

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
SKYBLUE='\033[0;36m'
NC='\033[0m'

check_root() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 用户运行${NC}"; exit 1; fi
}

create_shortcut() {
    if [ -f "$SCRIPT_PATH" ]; then
        chmod +x "$SCRIPT_PATH"
        ln -sf "$SCRIPT_PATH" "/usr/bin/$SHORTCUT_NAME"
        echo -e "${GREEN}快捷指令 '$SHORTCUT_NAME' 已创建${NC}"
    fi
}

get_current_env() {
    if pm2 describe node-proxy >/dev/null 2>&1; then
        CUR_UUID=$(pm2 describe node-proxy | grep "UUID" | awk '{print $4}' | tr -d "'" | tr -d '"')
        CUR_TOKEN=$(pm2 describe node-proxy | grep "ARGO_AUTH" | awk '{print $4}' | tr -d "'" | tr -d '"')
        CUR_DOMAIN=$(pm2 describe node-proxy | grep "ARGO_DOMAIN" | awk '{print $4}' | tr -d "'" | tr -d '"')
        # 获取当前端口
        CUR_PORT=$(pm2 describe node-proxy | grep "ARGO_PORT" | awk '{print $4}' | tr -d "'" | tr -d '"')
    else
        CUR_UUID=""
        CUR_TOKEN=""
        CUR_DOMAIN=""
        CUR_PORT="8001"
    fi
}

# --- 核心：一直等待直到获取到链接 ---
wait_for_link() {
    echo -e "${YELLOW}正在等待生成节点链接... (请不要关闭)${NC}"
    echo -e "如果时间过长，请检查 Token 是否正确"
    
    SECONDS=0
    TIMEOUT=60 # 设置一个建议超时，防止彻底卡死，但这里主要靠循环
    
    while true; do
        # 检查进程是否还活着
        if ! pm2 list | grep -q "node-proxy"; then
            echo -e "${RED}错误：服务已停止运行，请检查日志。${NC}"
            break
        fi

        # 搜索日志关键字
        if pm2 logs node-proxy --lines 100 --nostream | grep -q "SS 链接"; then
            echo -e "${GREEN}================ 节点信息 =================${NC}"
            # 打印包含链接的那几行
            pm2 logs node-proxy --lines 100 --nostream | grep -A 10 "\[SS 链接\]"
            echo -e "${GREEN}===========================================${NC}"
            break
        fi

        # 打印进度动画
        echo -n "."
        sleep 2
    done
}

install_app() {
    echo -e "${YELLOW}=== 开始安装 ===${NC}"
    if ! command -v node &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
        apt-get install -y nodejs git >/dev/null 2>&1
    fi
    if ! command -v pm2 &> /dev/null; then npm install -g pm2 >/dev/null 2>&1; fi

    rm -rf "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR"
    cd "$APP_DIR" || exit
    npm install

    # === [修改点] 交互式输入 ===
    read -p "请输入 UUID (回车随机): " IN_UUID
    read -p "请输入 Argo Token (必填): " IN_TOKEN
    read -p "请输入 Argo 域名 (必填): " IN_DOMAIN
    
    # 新增端口输入
    read -p "请输入 内部端口 (默认 8001): " IN_PORT
    if [ -z "$IN_PORT" ]; then IN_PORT="8001"; fi

    if [ -z "$IN_TOKEN" ] || [ -z "$IN_DOMAIN" ]; then
        echo -e "${RED}Token 和 域名不能为空！${NC}"
        return
    fi

    # 启动命令加入 ARGO_PORT
    ENV_STR="ARGO_AUTH='$IN_TOKEN' ARGO_DOMAIN='$IN_DOMAIN' ARGO_PORT='$IN_PORT'"
    if [ ! -z "$IN_UUID" ]; then ENV_STR="$ENV_STR UUID='$IN_UUID'"; fi
    
    pm2 delete node-proxy >/dev/null 2>&1
    eval "$ENV_STR pm2 start main.js --name node-proxy"
    pm2 save >/dev/null 2>&1
    pm2 startup | bash >/dev/null 2>&1
    
    create_shortcut
    echo -e "${GREEN}服务启动成功！${NC}"
    
    # 调用死循环等待函数
    wait_for_link
}

uninstall_app() {
    read -p "确定卸载? (y/n): " c
    if [ "$c" == "y" ]; then
        pm2 delete node-proxy >/dev/null 2>&1
        rm -rf "$APP_DIR" "/usr/bin/$SHORTCUT_NAME"
        echo -e "${GREEN}已卸载${NC}"
    fi
}

update_config() {
    get_current_env
    if [ -z "$CUR_TOKEN" ]; then echo -e "${RED}未运行${NC}"; return; fi
    
    echo -e "当前配置: UUID=${CUR_UUID} | 端口=${CUR_PORT} | 域名=${CUR_DOMAIN}"
    local TYPE=$1
    local NEW_VAL=""

    if [ "$TYPE" == "token" ]; then read -p "新 Token: " NEW_VAL; CUR_TOKEN=$NEW_VAL; fi
    if [ "$TYPE" == "domain" ]; then read -p "新 域名: " NEW_VAL; CUR_DOMAIN=$NEW_VAL; fi
    if [ "$TYPE" == "port" ]; then read -p "新 端口: " NEW_VAL; CUR_PORT=$NEW_VAL; fi

    if [ -z "$NEW_VAL" ]; then echo "不能为空"; return; fi

    pm2 delete node-proxy >/dev/null 2>&1
    # 重启时带上所有变量
    eval "ARGO_AUTH='$CUR_TOKEN' ARGO_DOMAIN='$CUR_DOMAIN' UUID='$CUR_UUID' ARGO_PORT='$CUR_PORT' pm2 start main.js --name node-proxy"
    pm2 save >/dev/null 2>&1
    
    echo -e "${GREEN}修改成功，正在等待重启...${NC}"
    sleep 2
    wait_for_link
}

show_menu() {
    clear
    echo -e "${SKYBLUE}=== SS-ARGO 管理 ($SHORTCUT_NAME) ===${NC}"
    if pm2 list | grep -q "node-proxy"; then echo -e "状态: ${GREEN}运行中${NC}"; else echo -e "状态: ${RED}未运行${NC}"; fi
    echo "1. 安装/重装 (自定义端口)"
    echo "2. 卸载"
    echo "3. 修改配置 (Token / 域名 / 端口)"
    echo "4. 查看节点链接 (强制刷新)"
    echo "0. 退出"
    read -p "选择: " choice

    case $choice in
        1) install_app ;;
        2) uninstall_app ;;
        3) 
            echo "1.Token 2.域名 3.端口"
            read -p "修改哪项: " sub
            if [ "$sub" == "1" ]; then update_config "token"; fi
            if [ "$sub" == "2" ]; then update_config "domain"; fi
            if [ "$sub" == "3" ]; then update_config "port"; fi
            ;;
        4) wait_for_link ;;
        0) exit 0 ;;
        *) echo "无效" ;;
    esac
    
    if [ "$choice" != "0" ]; then read -p "按回车返回..."; show_menu; fi
}

check_root
if [ "$0" != "/usr/bin/$SHORTCUT_NAME" ]; then create_shortcut >/dev/null 2>&1; fi
show_menu
