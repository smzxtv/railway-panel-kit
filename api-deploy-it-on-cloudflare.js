// =====================================================================
// api-deploy-it-on-cloudflare.js
// Cloudflare Worker — 多节点订阅聚合与管理 API
//
// 路由:
//   GET    /                          状态页(HTML)
//   GET    /sub?token=SUB_TOKEN       订阅(默认 base64; &format=links 明文链接;
//                                     &format=clash 输出 Clash.Meta YAML)
//   GET    /nodes?token=ADMIN_TOKEN   节点列表(JSON)
//   POST   /nodes?token=ADMIN_TOKEN   添加节点(body: JSON 节点对象, 写入 KV)
//   DELETE /nodes?id=xxx&token=...    删除节点(KV)
//   GET    /config?token=ADMIN_TOKEN  查看生效配置
//
// 数据源优先级: KV(NODES_KV) > CONFIG_URL(远程 config.json) > 内置 DEFAULT_CONFIG
// 部署: Cloudflare Dashboard 新建 Worker 粘贴本文件, 或 `wrangler deploy`
// 可选: 绑定 KV 命名空间 NODES_KV 以启用动态节点管理
// =====================================================================

// 与 config.json 保持一致; 若设置了 CONFIG_URL 则以远程为准
const DEFAULT_CONFIG = {
  subscription: {
    title: "My Proxy Nodes",
    subToken: "CHANGE_ME_SUB_TOKEN",
    adminToken: "CHANGE_ME_ADMIN_TOKEN",
    userInfo: "upload=0; download=0; total=107374182400; expire=0",
  },
  nodes: [],
};

export default {
  async fetch(request, env) {
    try {
      return await handleRequest(request, env);
    } catch (err) {
      return json({ success: false, msg: String(err) }, 500);
    }
  },
};

// ---------------------------------------------------------------- main
async function handleRequest(request, env) {
  const url = new URL(request.url);
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const config = await loadConfig(env);
  const sub = config.subscription || {};
  const subToken = env.SUB_TOKEN || sub.subToken || DEFAULT_CONFIG.subscription.subToken;
  const adminToken = env.ADMIN_TOKEN || sub.adminToken || DEFAULT_CONFIG.subscription.adminToken;
  const nodes = await loadNodes(env, config);

  switch (path) {
    case "/":
      return statusPage(nodes, sub);
    case "/sub":
      if (!checkToken(url, subToken)) return json({ success: false, msg: "unauthorized" }, 401);
      return subscription(nodes, sub, url.searchParams.get("format"));
    case "/nodes":
      if (!checkToken(url, adminToken)) return json({ success: false, msg: "unauthorized" }, 401);
      if (request.method === "POST") return addNode(env, request);
      if (request.method === "DELETE") return deleteNode(env, url);
      return json({ success: true, data: nodes });
    case "/config":
      if (!checkToken(url, adminToken)) return json({ success: false, msg: "unauthorized" }, 401);
      return json({ success: true, data: { subscription: { ...sub, subToken: "***", adminToken: "***" }, nodes } });
    default:
      return json({ success: false, msg: "not found" }, 404);
  }
}

// ---------------------------------------------------------------- config
async function loadConfig(env) {
  if (env.CONFIG_URL) {
    try {
      const resp = await fetch(env.CONFIG_URL, { cf: { cacheTtl: 300, cacheEverything: true } });
      if (resp.ok) return await resp.json();
    } catch (e) {
      console.log("CONFIG_URL fetch failed:", e);
    }
  }
  return DEFAULT_CONFIG;
}

// 节点优先取 KV(动态管理), 否则用配置文件里的静态节点
async function loadNodes(env, config) {
  if (env.NODES_KV) {
    const raw = await env.NODES_KV.get("nodes");
    if (raw) {
      try {
        return JSON.parse(raw);
      } catch (_) { /* fallthrough */ }
    }
  }
  return (config.nodes || []).filter((n) => n.enabled !== false);
}

async function saveNodes(env, nodes) {
  if (!env.NODES_KV) throw new Error("KV binding NODES_KV 未配置, 无法动态管理节点");
  await env.NODES_KV.put("nodes", JSON.stringify(nodes, null, 2));
}

function checkToken(url, expected) {
  const token = url.searchParams.get("token");
  return !!token && token === expected && !expected.startsWith("CHANGE_ME");
}

// ---------------------------------------------------------------- routes
async function addNode(env, request) {
  const node = await request.json();
  if (!node.host || !node.uuid || !node.name) {
    return json({ success: false, msg: "缺少必填字段: name/host/uuid" }, 400);
  }
  const nodes = await loadNodes(env, DEFAULT_CONFIG);
  node.id = node.id || `node-${Date.now()}`;
  node.protocol = node.protocol || "vless";
  node.port = node.port || 443;
  node.path = node.path || "/ws";
  node.tls = node.tls || "tls";
  node.enabled = node.enabled !== false;
  if (nodes.some((n) => n.id === node.id)) {
    return json({ success: false, msg: `节点已存在: ${node.id}` }, 409);
  }
  nodes.push(node);
  await saveNodes(env, nodes);
  return json({ success: true, data: node });
}

async function deleteNode(env, url) {
  const id = url.searchParams.get("id");
  const nodes = await loadNodes(env, DEFAULT_CONFIG);
  const next = nodes.filter((n) => n.id !== id);
  if (next.length === nodes.length) return json({ success: false, msg: `未找到节点: ${id}` }, 404);
  await saveNodes(env, next);
  return json({ success: true, data: next });
}

// ------------------------------------------------------------- subscription
function buildLink(node) {
  const host = node.host;
  const port = node.port || 443;
  const sni = node.sni || host;
  const name = encodeURIComponent(node.name || node.id);
  if (node.protocol === "vmess") {
    const v = {
      v: "2", ps: node.name || node.id, add: host, port: String(port),
      id: node.uuid, aid: String(node.alterId ?? 0), net: "ws", type: "none",
      host, path: node.path || "/ws", tls: node.tls === "tls" ? "tls" : "",
    };
    return `vmess://${btoa(JSON.stringify(v))}`;
  }
  // 默认 vless + ws (+tls, Railway/Cloudflare 边缘 TLS)
  const q = [
    `type=ws`,
    `encryption=none`,
    `security=${node.tls === "tls" ? "tls" : "none"}`,
    `host=${host}`,
    `sni=${sni}`,
    `path=${encodeURIComponent(node.path || "/ws")}`,
    `fp=chrome`,
    `alpn=http/1.1`,
  ].join("&");
  return `vless://${node.uuid}@${host}:${port}?${q}#${name}`;
}

async function subscription(nodes, sub, format) {
  const links = nodes.map(buildLink).join("\n");
  const title = sub.title || DEFAULT_CONFIG.subscription.title;
  const commonHeaders = {
    "Profile-Update-Interval": String(sub.updateInterval ?? 6),
    "Profile-Title": `base64:${toBase64Utf8(title)}`,
  };
  if (format === "links") {
    return new Response(links, { headers: { "Content-Type": "text/plain; charset=utf-8" } });
  }
  // Clash / Clash.Meta (mihomo) YAML 订阅
  if (format === "clash") {
    return new Response(clashYaml(nodes, sub), {
      headers: { "Content-Type": "text/yaml; charset=utf-8", ...commonHeaders },
    });
  }
  const body = toBase64Utf8(links);
  return new Response(body, {
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "Content-Disposition": `attachment; filename="${encodeURIComponent(title)}"`,
      "Subscription-Userinfo": sub.userInfo || DEFAULT_CONFIG.subscription.userInfo,
      ...commonHeaders,
    },
  });
}

// ------------------------------------------------------------- clash output
function yamlStr(s) {
  return String(s ?? "").replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function clashProxy(node) {
  const host = node.host;
  const port = Number(node.port || 443);
  const sni = node.sni || host;
  const name = yamlStr(node.name || node.id);
  const tls = node.tls === "tls";
  const isVmess = node.protocol === "vmess";
  const lines = [
    `  - name: "${name}"`,
    `    type: ${isVmess ? "vmess" : "vless"}`,
    `    server: ${host}`,
    `    port: ${port}`,
    `    udp: false`,
  ];
  if (isVmess) {
    lines.push(`    uuid: ${node.uuid}`, `    alterId: ${Number(node.alterId ?? 0)}`, `    cipher: auto`);
  } else {
    lines.push(`    uuid: ${node.uuid}`, `    flow: ""`, `    client-fingerprint: chrome`);
  }
  lines.push(`    tls: ${tls}`);
  if (tls) lines.push(`    servername: ${sni}`);
  lines.push(
    `    network: ws`,
    `    ws-opts:`,
    `      path: "${yamlStr(node.path || "/ws")}"`,
    `      headers:`,
    `        Host: ${host}`,
  );
  return lines.join("\n");
}

function clashYaml(nodes, sub) {
  const proxies = nodes.map(clashProxy).join("\n");
  const names = nodes.map((n) => `      - "${yamlStr(n.name || n.id)}"`).join("\n");
  const groupName = yamlStr(sub.title || DEFAULT_CONFIG.subscription.title);
  return `# Generated by node-sub-api worker
port: 7890
socks-port: 7891
allow-lan: false
mode: rule
log-level: info

proxies:
${proxies || "  []"}

proxy-groups:
  - name: "${groupName}"
    type: select
    proxies:
${names || '      - "DIRECT"'}

rules:
  - MATCH,${groupName}
`;
}

function toBase64Utf8(text) {
  const bytes = new TextEncoder().encode(text);
  let bin = "";
  bytes.forEach((b) => (bin += String.fromCharCode(b)));
  return btoa(bin);
}

// ---------------------------------------------------------------- pages
function statusPage(nodes, sub) {
  const list = nodes
    .map((n) => `<tr><td>${esc(n.name)}</td><td>${esc(n.protocol)}</td><td>${esc(n.host)}</td><td>${n.enabled !== false ? "✓" : "✗"}</td></tr>`)
    .join("");
  const html = `<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(sub.title || "Node Status")}</title>
<style>body{font-family:system-ui,sans-serif;background:#0d1117;color:#c9d1d9;max-width:760px;margin:40px auto;padding:0 16px}
table{width:100%;border-collapse:collapse;margin-top:16px}th,td{border:1px solid #30363d;padding:8px;text-align:left}
th{background:#161b22}h1{font-size:1.4rem}.muted{color:#8b949e;font-size:.9rem}</style></head>
<body><h1>${esc(sub.title || "Node Status")}</h1>
<p class="muted">共 ${nodes.length} 个节点 · 订阅: <code>/sub?token=***</code></p>
<table><tr><th>名称</th><th>协议</th><th>地址</th><th>启用</th></tr>${list || "<tr><td colspan=4>暂无节点</td></tr>"}</table>
</body></html>`;
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8" } });
}

function esc(s) {
  return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj, null, 2), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });
}
