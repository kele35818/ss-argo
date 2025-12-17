#!/bin/bash
# install.sh

# 你的仓库地址 (请修改这里)
REPO_URL="https://github.com/kele35818/ss-argo.git"
APP_DIR="/root/ss-argo"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 1. 检查 Root
if [ "$EUID" -ne 0 ]; then echo -e "${RED}请使用 root 运行${NC}"; exit 1; fi

# 2. 交互式获取参数
clear
echo -e "${GREEN}=== Node VPS 直连部署脚本 ===${NC}"
read -p "1. 请输入 UUID (回车随机生成): " IN_UUID
read -p "2. 请输入 Argo Token (必填): " IN_TOKEN
read -p "3. 请输入 Argo 域名 (必填): " IN_DOMAIN

if [ -z "$IN_TOKEN" ] || [ -z "$IN_DOMAIN" ]; then
    echo -e "${RED}Token 和 域名 必须填写！${NC}"
    exit 1
fi

# 3. 准备环境
echo -e "${YELLOW}安装 Node.js 和 PM2...${NC}"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
    apt-get install -y nodejs git >/dev/null 2>&1
fi
if ! command -v pm2 &> /dev/null; then npm install -g pm2 >/dev/null 2>&1; fi

# 4. 拉取代码
echo -e "${YELLOW}拉取代码...${NC}"
rm -rf "$APP_DIR"
git clone "$REPO_URL" "$APP_DIR" >/dev/null 2>&1
cd "$APP_DIR" || exit

# 5. 安装依赖 (不再需要 bytenode)
npm install axios express >/dev/null 2>&1

# 6. 启动服务 (PM2 直接运行 main.js)
echo -e "${YELLOW}启动服务...${NC}"
pm2 delete node-proxy >/dev/null 2>&1

# 组合环境变量
ENV_STR="ARGO_AUTH='$IN_TOKEN' ARGO_DOMAIN='$IN_DOMAIN'"
if [ ! -z "$IN_UUID" ]; then ENV_STR="$ENV_STR UUID='$IN_UUID'"; fi

# 启动
eval "$ENV_STR pm2 start main.js --name node-proxy"
pm2 save >/dev/null 2>&1
pm2 startup | bash >/dev/null 2>&1

# 7. 等待并打印链接
echo -e "${YELLOW}正在等待生成节点链接...${NC}"
sleep 5
# 抓取日志中的链接
( pm2 logs node-proxy --lines 0 & ) | grep -q "SS 链接"
sleep 1
# 打印日志最后 10 行
LOG_FILE=$(pm2 prettylist | grep "out_file" | awk -F '"' '{print $4}')
if [ -f "$LOG_FILE" ]; then
    echo -e "${GREEN}↓↓↓ 复制下方链接 ↓↓↓${NC}"
    grep -A 2 "\[SS 链接\]" "$LOG_FILE"
else
    echo -e "${RED}请手动运行 'pm2 logs node-proxy' 查看链接${NC}"
fi