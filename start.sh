#!/usr/bin/env bash
# =====================================================================
# 3X-UI on Railway — 容器入口脚本
#   1. 计算默认配置(端口/账号/UUID/路径), 全部可被环境变量覆盖
#   2. 渲染 nginx 配置并启动(对外唯一入口, 复用 Railway 单端口)
#   3. 启动前写入面板设置(账号/端口/访问路径)
#   4. 启动 3X-UI 面板, 并通过面板 API 自动创建 VLESS-WS 入站
# =====================================================================
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"

# ---------- 1. 基础配置(均可通过 Railway Variables 覆盖) ----------
export PORT="${PORT:-8080}"                                   # Railway 对外端口
export PANEL_PORT="${PANEL_PORT:-54321}"                      # 面板内部端口(仅容器内)
export XRAY_PORT="${XRAY_PORT:-10085}"                        # Xray WS 入站内部端口
export XUI_USERNAME="${XUI_USERNAME:-admin}"                  # 面板用户名
export XUI_PASSWORD="${XUI_PASSWORD:-$(openssl rand -hex 8)}" # 面板密码(默认随机)
export XUI_WEB_BASE_PATH="${XUI_WEB_BASE_PATH:-$(openssl rand -hex 4)}" # 面板路径
export VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
export VLESS_WS_PATH="${VLESS_WS_PATH:-ws}"                   # 代理 WS 路径
export NODE_NAME="${NODE_NAME:-railway-node}"                 # 节点名称
export PUBLIC_HOST="${PUBLIC_HOST:-${RAILWAY_PUBLIC_DOMAIN:-}}" # 对外域名(Railway 自动注入)

echo "[start] node        : ${NODE_NAME}"
echo "[start] public host : ${PUBLIC_HOST:-<未设置, 部署后请回填 PUBLIC_HOST>}"
echo "[start] panel url   : https://${PUBLIC_HOST}/${XUI_WEB_BASE_PATH}/"
echo "[start] panel login : ${XUI_USERNAME} / ${XUI_PASSWORD}"
echo "[start] vless uuid  : ${VLESS_UUID}   ws path: /${VLESS_WS_PATH}"

# ---------- 2. 渲染并启动 nginx ----------
NGINX_VARS='$PORT $PANEL_PORT $XUI_WEB_BASE_PATH $XRAY_PORT $VLESS_WS_PATH'
envsubst "${NGINX_VARS}" < "${APP_DIR}/nginx.conf.template" > /etc/nginx/nginx.conf
nginx -t
nginx
echo "[start] nginx started on :${PORT}"

cleanup() {
    echo "[start] 收到退出信号, 正在清理..."
    nginx -s stop 2>/dev/null || true
    if [[ -n "${PANEL_PID:-}" ]]; then
        kill "${PANEL_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# ---------- 3. 面板预设置(启动前写库) ----------
bash "${APP_DIR}/panel-bootstrap.sh" prestart

# ---------- 4. 前台启动面板 ----------
"${XUI_BIN}" run &
PANEL_PID=$!

# ---------- 5. 等面板就绪后自动创建入站节点并打印分享链接 ----------
bash "${APP_DIR}/panel-bootstrap.sh" poststart \
    || echo "[start] WARN: 自动创建入站失败, 可登录面板手动添加 VLESS-WS 入站"

echo "[start] ${NODE_NAME} 已就绪 ✓"
wait "${PANEL_PID}"
