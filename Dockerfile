# =====================================================================
# 3X-UI on Railway — 自动化容器化部署
# 构建: docker build -t 3x-ui-railway .
# 运行: docker run -p 8080:8080 3x-ui-railway
# =====================================================================
FROM ubuntu:22.04

ENV LANG=C.UTF-8 \
    TZ=Asia/Shanghai \
    DEBIAN_FRONTEND=noninteractive

# ---- 系统依赖: nginx(对外入口) + envsubst(渲染模板) + jq(组装 API JSON) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tzdata \
        nginx \
        gettext-base \
        jq \
        openssl \
        procps \
    && rm -rf /var/lib/apt/lists/*

# ---- 安装 3X-UI 官方发行版(自带 Xray) ----
RUN curl -fsSL -o /tmp/x-ui.tar.gz \
        "https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-amd64.tar.gz" \
    && tar -zxf /tmp/x-ui.tar.gz -C /tmp \
    && XUI_DIR="$(find /tmp -maxdepth 2 -type f -name 'x-ui' -print -quit | xargs dirname)" \
    && mv "${XUI_DIR}" /usr/local/x-ui \
    && chmod +x /usr/local/x-ui/x-ui \
    && rm -rf /tmp/* /tmp/.[!.]* /tmp/..?*

# ---- 应用脚本 ----
WORKDIR /app
COPY start.sh panel-bootstrap.sh nginx.conf.template /app/
RUN chmod +x /app/start.sh /app/panel-bootstrap.sh

ENV XUI_BIN=/usr/local/x-ui/x-ui

# Railway 会注入 PORT; 本地默认 8080
EXPOSE 8080

ENTRYPOINT ["/app/start.sh"]
