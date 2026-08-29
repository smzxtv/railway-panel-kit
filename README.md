# 3X-UI on Railway — 自动化容器化部署 + 多节点订阅聚合

将 [3X-UI 面板](https://github.com/MHSanaei/3x-ui) 一键部署到 Railway（或其他支持 Docker 的云平台），启动时自动完成面板初始化与 VLESS-WS 节点创建，并附带 Cloudflare Worker 多节点订阅聚合 API。

## 项目结构

```
├── Dockerfile                        # 容器镜像: Ubuntu + nginx + 3X-UI(自带 Xray)
├── start.sh                          # 容器入口: 渲染配置 -> 启动全流程编排
├── panel-bootstrap.sh                # 面板引导: 自动写设置 + API 创建入站节点
├── nginx.conf.template               # 单端口复用模板(面板/代理流量按路径分流)
├── config.json                       # 多节点清单(Worker 的静态数据源)
├── api-deploy-it-on-cloudflare.js    # Cloudflare Worker: 订阅聚合 + 节点管理 API
├── wrangler.toml                     # Worker 部署配置(可选)
└── README.md
```

## 架构

```
客户端 ──TLS──▶ Railway 单端口(443/边缘)
                  │ nginx (路径分流)
                  ├─ /{XUI_WEB_BASE_PATH}/  → 3X-UI 面板 (127.0.0.1:54321)
                  └─ /{VLESS_WS_PATH}       → Xray VLESS-WS (127.0.0.1:10085)

Cloudflare Worker(可选) ──聚合多个 Railway 节点──▶ /sub 统一订阅链接
```

> Railway 对每个服务只暴露一个公网端口，因此用 nginx 做路径分流，面板与代理流量共用同一入口；Railway 域名自带 TLS，客户端使用 `security=tls` 直连即可。

## 一、部署到 Railway

### 1. 准备仓库
把本项目推送到你的 GitHub 仓库（Dockerfile 必须在仓库根目录）。

### 2. 创建 Railway 服务
1. 登录 [railway.app](https://railway.app) → **New Project** → **Deploy from GitHub repo**，选择本仓库；
2. Railway 会自动检测 Dockerfile 并构建、启动；
3. 在 **Settings → Networking → Generate Domain** 生成域名（如 `xxx.up.railway.app`）。

### 3. 设置环境变量（Variables）

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `PUBLIC_HOST` | 建议 | `RAILWAY_PUBLIC_DOMAIN` | 对外域名，用于生成分享链接 |
| `XUI_USERNAME` | 否 | `admin` | 面板用户名 |
| `XUI_PASSWORD` | 否 | 随机 | 面板密码（**务必设置**） |
| `XUI_WEB_BASE_PATH` | 否 | 随机 8 位 | 面板访问路径 |
| `VLESS_UUID` | 否 | 随机 | 节点 UUID |
| `VLESS_WS_PATH` | 否 | `ws` | 代理 WS 路径 |
| `NODE_NAME` | 否 | `railway-node` | 节点名称 |
| `PORT` | 自动 | Railway 注入 | 对外端口 |

### 4. 获取节点信息
部署完成后查看 **Deployments → Logs**，启动脚本会打印：

- 面板地址：`https://<域名>/<XUI_WEB_BASE_PATH>/`（用户名/密码）
- `vless://...` 完整分享链接，可直接导入 v2rayN / v2rayNG / Shadowrocket / NekoBox 等客户端

## 二、多节点部署（横向扩容）

1. 在同一 Project 里对每个节点 **Duplicate Service**（复制服务），或连接同一仓库新建多个服务；
2. 给每个服务设置不同的 `NODE_NAME`、`VLESS_UUID`、`VLESS_WS_PATH`（避免订阅内路径冲突）；
3. 各自 Generate Domain，得到 `node-1.up.railway.app`、`node-2.up.railway.app` …；
4. 把所有节点填入 `config.json` 的 `nodes` 数组（或通过 Worker 的 KV API 动态添加），交给 Worker 聚合订阅。

### 节点字段说明（config.json）

```jsonc
{
  "id": "node-1",            // 唯一 ID
  "name": "Railway-Node-1",  // 客户端中显示的名称
  "protocol": "vless",       // vless | vmess
  "host": "xxx.up.railway.app",
  "port": 443,               // Railway 边缘 TLS 端口固定 443
  "uuid": "...",             // 与该节点 VLESS_UUID 一致
  "path": "/ws",             // 与该节点 VLESS_WS_PATH 一致
  "tls": "tls",
  "sni": "xxx.up.railway.app",
  "enabled": true
}
```

## 三、Cloudflare Worker 订阅聚合

### 方式 A：Dashboard 部署（无需命令行）
1. Cloudflare Dashboard → **Workers & Pages** → **Create Worker**；
2. 将 `api-deploy-it-on-cloudflare.js` 全文粘贴进编辑器并部署；
3. 在 **Settings → Variables** 添加：
   - `SUB_TOKEN`（订阅访问令牌）
   - `ADMIN_TOKEN`（管理令牌）
   - `CONFIG_URL`（可选：指向你仓库中 `config.json` 的 raw 地址，Worker 每 5 分钟刷新）
   - `NODES_KV`（可选：绑定 KV 命名空间后可动态增删节点）

### 方式 B：Wrangler 部署
```bash
npm i -g wrangler
wrangler login
# 编辑 wrangler.toml: name / KV id / vars
wrangler deploy
```

### API 一览

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET /` | 状态页 | 节点列表概览 |
| `GET /sub?token=SUB_TOKEN` | 订阅 | 默认 base64（v2rayN/Shadowrocket 等）；`&format=links` 明文链接；`&format=clash` Clash.Meta YAML |
| `GET /nodes?token=ADMIN_TOKEN` | 节点列表 | JSON |
| `POST /nodes?token=ADMIN_TOKEN` | 添加节点 | body 为节点 JSON（需 KV） |
| `DELETE /nodes?id=node-1&token=ADMIN_TOKEN` | 删除节点 | 按 id 删除（需 KV） |
| `GET /config?token=ADMIN_TOKEN` | 生效配置 | token 打码 |

### 客户端使用
把 `https://<你的-worker域名>/sub?token=SUB_TOKEN` 作为订阅链接添加到 v2rayN / v2rayNG / Shadowrocket / Clash Meta 等客户端，即可自动获取全部节点并随 `updateInterval` 更新。Clash 客户端（Clash Verge / mihomo）可直接用 `?token=...&format=clash`。

## 三·五、GitHub Actions 自动部署（push 即部署）

仓库里已包含 `.github/workflows/deploy-railway.yml`，配置一次后每次 push 到 `main` 会自动把 Dockerfile 构建并部署到 Railway，也可在 Actions 页面手动触发。

### 配置步骤

1. **获取 Railway Token**：Railway 项目 → Settings → **Tokens** → 创建一个**环境级 Token**（选择 production 环境），复制保存；
2. GitHub 仓库 → **Settings → Secrets and variables → Actions**：
   - **Secrets** 里新建 `RAILWAY_TOKEN`，粘贴上面的 token；
   - **Variables** 里新建 `RAILWAY_SERVICES`（可选），值为 JSON 数组的服务名列表，例如：
     ```json
     ["railway-node-1", "railway-node-2"]
     ```
3. 完成。push 到 `main` 即自动部署所有列出的服务（矩阵并行、互不影响）；未配置 `RAILWAY_SERVICES` 时默认部署名为 `railway-node` 的服务。

> 注意：token 等同于部署权限，务必放在 **Secrets** 而不是 Variables；多节点扩容时把新服务名追加进 `RAILWAY_SERVICES` 即可。


## 四、本地测试

```bash
docker build -t 3x-ui-railway .
docker run --rm -p 8080:8080 \
  -e PUBLIC_HOST=localhost:8080 \
  -e XUI_PASSWORD=test123456 \
  -e VLESS_WS_PATH=ws \
  3x-ui-railway
# 面板: http://localhost:8080/<XUI_WEB_BASE_PATH>/  (路径看日志)
```

> 注意：本地用 `PUBLIC_HOST=localhost:8080` 生成的链接是 `https://` 前缀，本地明文测试请手动把链接里的 `security=tls` 改为 `security=none`、端口改 8080。

## 五、常见问题

- **面板 502/打不开**：检查日志中 `panel url`，确认访问时带上了随机 `XUI_WEB_BASE_PATH`；根路径 `/` 故意返回 404。
- **代理连不上**：确认客户端 `path` 与 `VLESS_WS_PATH` 一致、`sni/host` 为 Railway 域名、`security=tls`。
- **重新部署后密码/UUID 变了**：Railway 容器存储是临时的，所有配置由环境变量驱动，固定值请写在 Variables 里。
- **数据持久化**：Railway 容器存储是临时的，如需保留面板数据库，可挂载 Railway Volume 到 `/etc/x-ui`（面板 SQLite 数据库位于 `/etc/x-ui/x-ui.db`）。

## ⚠️ 免责声明

本项目仅供学习、研究和网络调试等技术用途。Railway 的服务条款对代理/翻墙类用途有明确限制，部署前请自行确认平台政策与当地法律法规，风险自负。请勿用于非法用途。
