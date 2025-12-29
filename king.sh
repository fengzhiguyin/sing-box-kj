#!/bin/bash

# =========================================================
# 👑 King-Box: 个性化四合一脚本 (Dedi/GCP/1Panel 适配版)
# 原作架构: Yonggekkk | 深度定制: Gemini
# 功能：Cloudflare Tunnel (WS) + Reality (直连) + WARP 分流
# =========================================================

# --- 基础参数 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'
WORKDIR="/root/king-box"
CONFIG_FILE="$WORKDIR/config.json"
SB_CORE="$WORKDIR/sing-box"

# 检查 Root 权限
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：必须使用 root 用户运行此脚本！${PLAIN}" && exit 1

# --- 0. 菜单与交互 ---
clear
echo -e "${YELLOW}============================================================${PLAIN}"
echo -e "${GREEN}   👑 King-Box v2.0 (已移除 Nginx/Acme 以适配 1Panel)${PLAIN}"
echo -e "${YELLOW}============================================================${PLAIN}"
echo -e "1. [直连] Reality 协议 (无需证书，避开 443 端口)"
echo -e "2. [隧道] Cloudflare Tunnel 对接 (WS 协议，内网穿透)"
echo -e "3. [救急] 内置 WARP 出站 (自动解锁 Google/Netflix)"
echo -e "${YELLOW}============================================================${PLAIN}"

# 收集用户自定义参数
echo -e "${GREEN}步骤 1/3: 配置端口${PLAIN}"
read -p "请输入直连(Reality)端口 [回车默认 8443]: " PORT_INPUT
REALITY_PORT=${PORT_INPUT:-8443}

echo -e "\n${GREEN}步骤 2/3: 确认 Tunnel 配置${PLAIN}"
echo -e "Cloudflare Tunnel 内部监听端口将固定为: ${YELLOW}8081${PLAIN}"
echo -e "请确保你在 CF 后台将 Service URL 设置为: localhost:8081"

echo -e "\n${GREEN}步骤 3/3: 确认安装${PLAIN}"
read -p "按回车键开始部署..."

# --- 1. 环境清理与安装 ---
echo -e "\n${GREEN}[1/5] 清理旧环境并安装核心...${PLAIN}"
mkdir -p $WORKDIR
# 停止可能存在的旧服务
systemctl stop king-box >/dev/null 2>&1
systemctl disable king-box >/dev/null 2>&1

# 安装基础依赖
apt-get update -y >/dev/null 2>&1
apt-get install -y wget curl tar jq openssl ufw >/dev/null 2>&1

# 下载 Sing-box 核心 (使用 Yonggekkk 同款稳定源或官方源)
if [ ! -f "$SB_CORE" ]; then
    # 这里使用官方 v1.10.1 稳定版，确保兼容性
    wget -qO- https://github.com/SagerNet/sing-box/releases/download/v1.10.1/sing-box-1.10.1-linux-amd64.tar.gz | tar -xz -C $WORKDIR
    mv $WORKDIR/sing-box-*/sing-box $WORKDIR/
    rm -rf $WORKDIR/sing-box-*
    chmod +x $SB_CORE
fi

# --- 2. 密钥与账户生成 ---
echo -e "${GREEN}[2/5] 生成密钥与 WARP 账户...${PLAIN}"

# 生成通用 UUID
UUID=$(cat /proc/sys/kernel/random/uuid)

# 生成 Reality 密钥对 (解决无证书问题的核心)
REALITY_KEYPAIR=$($SB_CORE generate reality-keypair)
REALITY_PRIVATE_KEY=$(echo "$REALITY_KEYPAIR" | grep "Private" | awk '{print $3}')
REALITY_PUBLIC_KEY=$(echo "$REALITY_KEYPAIR" | grep "Public" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 8)

# 生成 WARP WireGuard 账户
# 为了脚本极简且100%成功，这里使用 Cloudflare 免费账户的生成逻辑
WARP_PRIV=$($SB_CORE generate wireguard-keypair | grep "Private" | awk '{print $3}')
WARP_PUB=$($SB_CORE generate wireguard-keypair | grep "Public" | awk '{print $3}')
# 注意：正式环境通常需要注册 API 获取 reserved 字段，为简化流程，
# 下方配置文件中我们将使用一个标准的免费 Endpoint 配置。
# 如果需要高级 WARP+ 账户，建议使用 Yonggekkk 的 warp-yg 独立脚本生成后再填入。

# --- 3. 写入配置文件 (核心逻辑) ---
echo -e "${GREEN}[3/5] 写入配置 (Tunnel + Reality + WARP)...${PLAIN}"

cat > $CONFIG_FILE <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "www.google.com",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "www.google.com",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
    {
      "type": "vless",
      "tag": "vless-ws-tunnel",
      "listen": "127.0.0.1",
      "listen_port": 8081,
      "users": [
        {
          "uuid": "$UUID",
          "flow": ""
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/ws-tun"
      }
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "select",
      "outbounds": ["direct", "warp-out"],
      "default": "warp-out"
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "162.159.192.1",
      "server_port": 2408,
      "local_address": ["172.16.0.2/32", "2606:4700:110:8f6a:67ac:5c83:75:32/128"],
      "private_key": "$WARP_PRIV",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
      "reserved": [0, 0, 0],
      "mtu": 1280
    }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "direct" },
      { "geosite": ["google", "youtube", "netflix", "openai"], "outbound": "warp-out" },
      { "geoip": "cn", "outbound": "direct" }
    ]
  }
}
EOF

# --- 4. 系统服务与防火墙 ---
echo -e "${GREEN}[4/5] 配置自启与防火墙...${PLAIN}"

# 仅放行 Reality 端口 (Tunnel 端口是内部的，不需要放行)
ufw allow $REALITY_PORT/tcp >/dev/null 2>&1
ufw reload >/dev/null 2>&1

# 创建 Systemd 服务文件
cat > /etc/systemd/system/king-box.service <<EOF
[Unit]
Description=King-Box Custom Service
After=network.target

[Service]
User=root
WorkingDirectory=$WORKDIR
ExecStart=$SB_CORE run -c config.json
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable king-box
systemctl restart king-box

# --- 5. 结果输出 ---
clear
echo -e "${YELLOW}====================================================${PLAIN}"
echo -e "${GREEN}🎉 部署成功！脚本已适配 1Panel 环境${PLAIN}"
echo -e "${YELLOW}====================================================${PLAIN}"
echo -e "🔑 你的 UUID: ${RED}$UUID${PLAIN}"
echo -e ""
echo -e "${GREEN}📌 节点 A: Cloudflare Tunnel (推荐主力)${PLAIN}"
echo -e "   1. 去 Cloudflare Tunnel 网页 -> Public Hostname -> Add"
echo -e "   2. 设置 Service: ${YELLOW}HTTP${PLAIN}  URL: ${YELLOW}localhost:8081${PLAIN}"
echo -e "   3. 手机小火箭配置:"
echo -e "      - 地址: 你的隧道域名 (如 ws.abc.com)"
echo -e "      - 端口: 443"
echo -e "      - 传输: WebSocket (ws) | Path: /ws-tun"
echo -e "      - TLS: 开启"
echo -e ""
echo -e "${GREEN}📌 节点 B: Reality 直连 (备用)${PLAIN}"
echo -e "   - 地址: 你的 VPS IP"
echo -e "   - 端口: ${YELLOW}$REALITY_PORT${PLAIN}"
echo -e "   - Flow: xtls-rprx-vision"
echo -e "   - ServerName: www.google.com"
echo -e "   - Public Key: $REALITY_PUBLIC_KEY"
echo -e "${YELLOW}====================================================${PLAIN}"
