const express = require("express");
const app = express();
const axios = require("axios");
const fs = require("fs");
const path = require("path");
const { promisify } = require('util');
const exec = promisify(require('child_process').exec);
const crypto = require('crypto');

// --- 环境变量配置 ---
const FILE_PATH = process.env.FILE_PATH || './tmp';
const PORT = process.env.PORT || 3000;
const UUID = process.env.UUID || crypto.randomUUID();

// 1. 核心 Argo 参数
const ARGO_DOMAIN = process.env.ARGO_DOMAIN;
const ARGO_AUTH = process.env.ARGO_AUTH;
// [修改点] 接收自定义端口，默认 8001
const ARGO_PORT = process.env.ARGO_PORT || 8001; 

const CFIP = process.env.CFIP || 'cdns.doon.eu.org';
const CFPORT = process.env.CFPORT || 443;
const NAME = process.env.NAME || 'SS-ARGO';

if (!ARGO_DOMAIN || !ARGO_AUTH) {
    console.error("Error: ARGO_DOMAIN and ARGO_AUTH are required.");
    process.exit(1);
}

const SS_METHOD = 'chacha20-ietf-poly1305'; 
const SS_PASSWORD = UUID;
const SS_PATH = '/ss-argo';

process.on('uncaughtException', function (err) { console.error(err); });
if (!fs.existsSync(FILE_PATH)) fs.mkdirSync(FILE_PATH);

const webName = 'web'; // 固定文件名，方便清理
const botName = 'bot';
let webPath = path.join(FILE_PATH, webName);
let botPath = path.join(FILE_PATH, botName);
let subPath = path.join(FILE_PATH, 'sub.txt');
let configPath = path.join(FILE_PATH, 'config.json');

function cleanupOldFiles() {
    try {
        // 启动前先杀进程，防止端口占用
        try { require('child_process').execSync(`pkill -f ${webName}`); } catch (e) {}
        try { require('child_process').execSync(`pkill -f ${botName}`); } catch (e) {}
    } catch (err) {}
}

app.get("/", function(req, res) { res.send("Node Proxy is Running."); });

async function generateConfig() {
  const config = {
    log: { access: '/dev/null', error: '/dev/null', loglevel: 'none' },
    inbounds: [
      {
        port: parseInt(ARGO_PORT), // 使用自定义端口
        listen: "127.0.0.1",
        protocol: "shadowsocks",
        settings: {
          method: SS_METHOD,
          password: SS_PASSWORD,
          network: "tcp,udp"
        },
        streamSettings: {
          network: "ws",
          wsSettings: { path: SS_PATH }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }
    ],
    dns: { servers: ["https+local://8.8.8.8/dns-query"] },
    outbounds: [ { protocol: "freedom", tag: "direct" }, { protocol: "blackhole", tag: "block" } ]
  };
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
}

function downloadFile(fileName, fileUrl) {
  return new Promise((resolve, reject) => {
    const writer = fs.createWriteStream(fileName);
    axios({ method: 'get', url: fileUrl, responseType: 'stream', timeout: 30000 })
      .then(response => {
        response.data.pipe(writer);
        writer.on('finish', () => { writer.close(); resolve(); });
        writer.on('error', err => { fs.unlink(fileName, () => {}); reject(err); });
      })
      .catch(err => reject(err));
  });
}

function createArgoConfig() {
  if (ARGO_AUTH.includes('TunnelSecret')) {
    try {
        fs.writeFileSync(path.join(FILE_PATH, 'tunnel.json'), ARGO_AUTH);
        const tunnelYaml = `
tunnel: ${ARGO_AUTH.split('"')[11]}
credentials-file: ${path.join(FILE_PATH, 'tunnel.json')}
protocol: http2
ingress:
  - hostname: ${ARGO_DOMAIN}
    service: http://localhost:${ARGO_PORT} 
    originRequest:
      noTLSVerify: true
  - service: http_status:404
`;
        fs.writeFileSync(path.join(FILE_PATH, 'tunnel.yml'), tunnelYaml);
    } catch (e) { console.error(e); }
  }
}

async function downloadFilesAndRun() {  
  // 这里的链接请确保是你的仓库地址，或者保持不变
  const filesToDownload = [
      { fileName: webPath, fileUrl: "https://github.com/kele35818/nodejs/raw/refs/heads/main/web" },
      { fileName: botPath, fileUrl: "https://github.com/kele35818/nodejs/raw/refs/heads/main/bot" }
  ];

  try {
      await Promise.all(filesToDownload.map(f => downloadFile(f.fileName, f.fileUrl)));
  } catch (err) { 
      console.log("Download failed or files exist, trying to run local...");
  }
  
  [webPath, botPath].forEach(f => { if(fs.existsSync(f)) fs.chmodSync(f, 0o775); });

  try { await exec(`nohup ${webPath} -c ${configPath} >/dev/null 2>&1 &`); } catch (e) {}

  if (fs.existsSync(botPath)) {
    let args;
    if (ARGO_AUTH.match(/^[A-Z0-9a-z=]{120,250}$/)) {
        args = `tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_AUTH}`;
    } else if (ARGO_AUTH.match(/TunnelSecret/)) {
        args = `tunnel --edge-ip-version auto --config ${path.join(FILE_PATH, 'tunnel.yml')} run`;
    }
    if (args) { try { await exec(`nohup ${botPath} ${args} >/dev/null 2>&1 &`); } catch (e) {} }
  }
}

async function extractDomains() {
  setTimeout(() => {
    const ssUserInfo = Buffer.from(`${SS_METHOD}:${SS_PASSWORD}`).toString('base64');
    const ssPluginOpts = `v2ray-plugin;mode=websocket;host=${ARGO_DOMAIN};path=${SS_PATH};tls;sni=${ARGO_DOMAIN}`;
    const ssLink = `ss://${ssUserInfo}@${CFIP}:${CFPORT}?plugin=${encodeURIComponent(ssPluginOpts)}#${NAME}`;

    console.log("\n==================================================");
    console.log("             节点部署成功！链接如下                 ");
    console.log("==================================================");
    console.log("\n[SS 链接]:");
    console.log(ssLink); 
    console.log("==================================================\n");
    
    fs.writeFileSync(subPath, Buffer.from(ssLink).toString('base64'));
  }, 5000); // 稍微延时 5 秒确保服务启动
}

async function startserver() {
  try {
    cleanupOldFiles();
    createArgoConfig();
    await generateConfig();
    await downloadFilesAndRun();
    await extractDomains();
  } catch (error) { console.error(error); }
}

startserver();
app.listen(PORT, () => console.log(`App running on port ${PORT}`));
