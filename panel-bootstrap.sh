#!/usr/bin/env bash
# =====================================================================
# 3X-UI 面板自动化引导脚本
# 用法: panel-bootstrap.sh prestart|poststart
#   prestart  — 面板启动前: 通过 x-ui CLI 写入端口/账号/路径
#   poststart — 面板启动后: 调用面板 API 自动创建 VLESS-WS 入站 + 打印链接
# =====================================================================
set -euo pipefail

XUI_BIN="${XUI_BIN:-/usr/local/x-ui/x-ui}"
PANEL_PORT="${PANEL_PORT:-54321}"
XUI_USERNAME="${XUI_USERNAME:-admin}"
XUI_PASSWORD="${XUI_PASSWORD:-admin}"
XUI_WEB_BASE_PATH="${XUI_WEB_BASE_PATH:-panel}"
XRAY_PORT="${XRAY_PORT:-10085}"
VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"
VLESS_WS_PATH="${VLESS_WS_PATH:-ws}"
NODE_NAME="${NODE_NAME:-railway-node}"
PUBLIC_HOST="${PUBLIC_HOST:-${RAILWAY_PUBLIC_DOMAIN:-}}"
COOKIE_FILE="/tmp/.xui-cookie"
INBOUND_TAG="inbound-vless-ws"

PHASE="${1:-poststart}"

panel_base() {
    echo "http://127.0.0.1:${PANEL_PORT}/${XUI_WEB_BASE_PATH}"
}

# ---------------------------------------------------------------
# Phase 1: 启动前面板设置(CLI 会自动初始化数据库)
# ---------------------------------------------------------------
do_prestart() {
    echo "[bootstrap] 写入面板设置: port=${PANEL_PORT} user=${XUI_USERNAME} path=/${XUI_WEB_BASE_PATH}/"
    "${XUI_BIN}" setting \
        -port "${PANEL_PORT}" \
        -username "${XUI_USERNAME}" \
        -password "${XUI_PASSWORD}" \
        -webBasePath "/${XUI_WEB_BASE_PATH}/"
    echo "[bootstrap] 面板设置完成 ✓"
}

wait_panel() {
    local base code i
    base="$(panel_base)"
    for i in $(seq 1 60); do
        code="$(curl -s -o /dev/null -w '%{http_code}' "${base}/" || true)"
        if [[ "${code}" == "200" || "${code}" == "302" ]]; then
            echo "[bootstrap] 面板已就绪 (等待 ${i}s)"
            return 0
        fi
        sleep 1
    done
    echo "[bootstrap] ERROR: 等待面板超时"
    return 1
}

do_login() {
    local base resp token success attempt
    base="$(panel_base)"

    # v3.7+ 登录需要 CSRF token: 先 GET /csrf-token(同一会话), 再带着 token 登录
    token="$(curl -s -c "${COOKIE_FILE}" "${base}/csrf-token" \
        | jq -r '.obj // empty' 2>/dev/null || true)"
    if [[ -z "${token}" ]]; then
        echo "[bootstrap] ERROR: 获取 CSRF token 失败"
        return 1
    fi

    for attempt in 1 2 3; do
        resp="$(curl -s -b "${COOKIE_FILE}" -c "${COOKIE_FILE}" -X POST "${base}/login" \
            -H "X-CSRF-Token: ${token}" \
            --data-urlencode "username=${XUI_USERNAME}" \
            --data-urlencode "password=${XUI_PASSWORD}" \
            --data-urlencode "_csrf=${token}")"
        success="$(echo "${resp}" | jq -r '.success // false' 2>/dev/null || echo false)"
        if [[ "${success}" == "true" ]]; then
            echo "[bootstrap] 面板登录成功 ✓"
            return 0
        fi
        echo "[bootstrap] 登录失败(第 ${attempt} 次): ${resp}"
        sleep 3
    done
    echo "[bootstrap] ERROR: 面板登录失败: ${resp}"
    return 1
}

# ---------------------------------------------------------------
# Phase 2: 通过 API 创建 VLESS-WS 入站
# ---------------------------------------------------------------
do_poststart() {
    wait_panel
    do_login

    # 已存在同 tag 入站则跳过
    local existing
    existing="$(curl -s -b "${COOKIE_FILE}" "$(panel_base)/panel/api/inbounds/list" \
        | jq -r --arg tag "${INBOUND_TAG}" '[.data[]? | select(.tag == $tag)] | length' 2>/dev/null || echo 0)"
    if [[ "${existing}" != "0" ]]; then
        echo "[bootstrap] 入站 ${INBOUND_TAG} 已存在, 跳过创建"
        print_share_link
        return 0
    fi

    local settings stream inbound resp success msg csrf
    # v3.7 全站 CSRF 保护: 创建入站的 POST 请求也必须带 token
    csrf="$(curl -s -b "${COOKIE_FILE}" "$(panel_base)/csrf-token" \
        | jq -r '.obj // empty' 2>/dev/null || true)"
    if [[ -z "${csrf}" ]]; then
        echo "[bootstrap] ERROR: 获取 CSRF token 失败"
        return 1
    fi
    settings="$(jq -cn --arg uuid "${VLESS_UUID}" '
        {clients:[{id:$uuid,flow:"",email:"railway-user",limitIp:0,totalGB:0,
                   expiryTime:0,enable:true,tgId:0,subId:"railway",reset:0}],
         decryption:"none",fallbacks:[]}')"
    stream="$(jq -cn --arg path "/${VLESS_WS_PATH}" '
        {network:"ws",security:"none",externalProxy:[],
         wsSettings:{acceptProxyProtocol:false,path:$path,headers:{}}}')"
    inbound="$(jq -cn --argjson port "${XRAY_PORT}" \
                    --arg settings "${settings}" \
                    --arg stream "${stream}" \
                    --arg remark "${NODE_NAME}" \
                    --arg tag "${INBOUND_TAG}" '
        {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,listen:"",
         port:$port,protocol:"vless",settings:$settings,streamSettings:$stream,
         sniffing:"{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fhttp\"]}",
         tag:$tag}')"

    resp="$(curl -s -b "${COOKIE_FILE}" -X POST "$(panel_base)/panel/api/inbounds/add" \
        -H 'Content-Type: application/json' \
        -H "X-CSRF-Token: ${csrf}" \
        -d "${inbound}")"
    success="$(echo "${resp}" | jq -r '.success // false' 2>/dev/null || echo false)"
    msg="$(echo "${resp}" | jq -r '.msg // ""' 2>/dev/null || true)"
    if [[ "${success}" != "true" ]]; then
        echo "[bootstrap] ERROR: 创建入站失败: ${msg:-${resp}}"
        return 1
    fi
    echo "[bootstrap] VLESS-WS 入站创建成功 ✓ (127.0.0.1:${XRAY_PORT}, path=/${VLESS_WS_PATH})"
    print_share_link
}

print_share_link() {
    if [[ -z "${PUBLIC_HOST}" ]]; then
        echo "[bootstrap] 未检测到对外域名, 请设置 PUBLIC_HOST 或部署后回填 RAILWAY_PUBLIC_DOMAIN"
        return 0
    fi
    local query link
    query="type=ws&encryption=none&security=tls&host=${PUBLIC_HOST}&sni=${PUBLIC_HOST}"
    query+="&path=%2F${VLESS_WS_PATH}&fp=chrome&alpn=http%2F1.1"
    link="vless://${VLESS_UUID}@${PUBLIC_HOST}:443?${query}#${NODE_NAME}"
    echo "=============================================================="
    echo "[bootstrap] VLESS 分享链接 (直接导入客户端):"
    echo "${link}"
    echo "=============================================================="
}

case "${PHASE}" in
    prestart)  do_prestart ;;
    poststart) do_poststart ;;
    *) echo "用法: $0 prestart|poststart"; exit 1 ;;
esac
