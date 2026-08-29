import worker from "./api-deploy-it-on-cloudflare.js";

const kv = { store: {}, get(k) { return this.store[k] ?? null; }, put(k, v) { this.store[k] = v; } };
const env = { SUB_TOKEN: "s1", ADMIN_TOKEN: "a1", NODES_KV: kv };

await kv.put("nodes", JSON.stringify([
  { id: "n1", name: 'Node "A"', protocol: "vless", host: "n1.up.railway.app", port: 443, uuid: "u-1", path: "/ws", tls: "tls" },
  { id: "n2", name: "NodeB", protocol: "vmess", host: "n2.up.railway.app", port: 443, uuid: "u-2", path: "/ws2", tls: "tls" },
]));

let r = await worker.fetch(new Request("http://x/sub?token=s1&format=clash"), env);
const yaml = await r.text();
console.log("clash status:", r.status, "| bytes:", yaml.length);
console.log("--- clash yaml ---");
console.log(yaml);

r = await worker.fetch(new Request("http://x/sub?token=s1"), env);
console.log("base64 sub status:", r.status, "| decoded:", Buffer.from(await r.text(), "base64").toString().slice(0, 100), "...");
r = await worker.fetch(new Request("http://x/"), env);
console.log("status page:", r.status);
r = await worker.fetch(new Request("http://x/sub?token=s1&format=links"), env);
console.log("links:", (await r.text()).split("\n").length, "line(s)");
