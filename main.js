const express = require("express");
const app = express();
const axios = require("axios");
const fs = require("fs");
const path = require("path");
const { promisify } = require('util');
const exec = promisify(require('child_process').exec);
const { execSync } = require('child_process');
const crypto = require('crypto'); // 用于生成随机 UUID

// --- 环境变量配置 (无硬编码) ---
const FILE_PATH = process.env.FILE_PATH || './tmp';
const PORT = process.env.PORT || 3000;

// 1. UUID: 优先读取环境变量，否则随机生成
const UUID = process.env.UUID || crypto.randomUUID();

// 2. Argo 参数: 必须通过环境变量传入，否则无法运行
const ARGO_DOMAIN = process.env.ARGO_DOMAIN;
const ARGO_AUTH = process.env.ARGO_AUTH;

// 3. 其他默认配置
const ARGO_PORT = process.env.ARGO_PORT || 8001;
const CFIP = process.env.CFIP || 'cdns.doon.eu.org';
const CFPORT = process.env.CFPORT || 443;
const NAME = process.env.NAME || 'VPS';

// --- 检查必要参数 ---
if (!ARGO_DOMAIN || !ARGO_AUTH) {
    console.error("Error: ARGO_DOMAIN and ARGO_AUTH environment variables are required.");
    process.exit(1);
}

const SS_METHOD = 'chacha20-ietf-poly1305'; 
const SS_PASSWORD = UUID;
const SS_PATH = '/ss-argo';

// --- 全局错误处理 ---
process.on('uncaughtException', function (err) {
    console.error('Caught exception: ', err);
});

if (!fs.existsSync(FILE_PATH)) {
  fs.mkdirSync(FILE_PATH);
}

function generateRandomName() {
  const characters = 'abcdefghijklmnopqrstuvwxyz';
  let result = '';
  for (let i = 0; i < 6; i++) {
    result += characters.charAt(Math.floor(Math.random() * characters.length));
  }
  return result;
}

const webName = generateRandomName();
const botName = generateRandomName();
let webPath = path.join(FILE_PATH, webName);
let botPath = path.join(FILE_PATH, botName);
let subPath = path.join(FILE_PATH, 'sub.txt');
let configPath = path.join(FILE_PATH, 'config.json');

function cleanupOldFiles() {
    try {
        if (!fs.existsSync(FILE_PATH)) return;
        const files = fs.readdirSync(FILE_PATH);
        files.forEach(file => {
            const curPath = path.join(FILE_PATH, file);
            if (fs.statSync(curPath).isFile()) {
                fs.unlinkSync(curPath);
            }
        });
    } catch (err) {}
}

app.get("/", function(req, res) {
  res.send("Node Proxy is Running.");
});

async function generateConfig() {
  const config = {
    log: { access: '/dev/null', error: '/dev/null', loglevel: 'none' },
    inbounds: [
      {
        port: ARGO_PORT,
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
        sniffing: {
          enabled: true,
          destOverride: ["http", "tls", "quic"],
          metadataOnly: false
        }
      }
    ],
    dns: { servers: ["https+local://8.8.8.8/dns-query", "https+local://1.1.1.1/dns-query"] },
    outbounds: [ { protocol: "freedom", tag: "direct" }, { protocol: "blackhole", tag: "block" } ]
  };
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
}

function downloadFile(fileName, fileUrl, callback) {
  const writer = fs.createWriteStream(fileName);
  axios({
    method: 'get',
    url: fileUrl,
    responseType: 'stream',
    timeout: 30000
  })
    .then(response => {
      response.data.pipe(writer);
      writer.on('finish', () => {
        writer.close();
        callback(null, fileName);
      });
      writer.on('error', err => {
        fs.unlink(fileName, () => {});
        callback(err.message);
      });
    })
    .catch(err => callback(err.message));
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
  const filesToDownload = [
      { fileName: webPath, fileUrl: "https://github.com/kele35818/nodejs/raw/refs/heads/main/web" },
      { fileName: botPath, fileUrl: "https://github.com/kele35818/nodejs/raw/refs/heads/main/bot" }
  ];

  const downloadPromises = filesToDownload.map(f => {
    return new Promise((resolve, reject) => {
      downloadFile(f.fileName, f.fileUrl, (err) => err ? reject(err) : resolve());
    });
  });

  try { await Promise.all(downloadPromises); } catch (err) { return; }
  
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
  const nodeName = NAME;
  setTimeout(() => {
    const ssUserInfo = Buffer.from(`${SS_METHOD}:${SS_PASSWORD}`).toString('base64');
    const ssPluginOpts = `v2ray-plugin;mode=websocket;host=${ARGO_DOMAIN};path=${SS_PATH};tls;sni=${ARGO_DOMAIN}`;
    const ssLink = `ss://${ssUserInfo}@${CFIP}:${CFPORT}?plugin=${encodeURIComponent(ssPluginOpts)}#${nodeName}`;

    console.log("\n==================================================");
    console.log("             节点部署成功！链接如下                 ");
    console.log("==================================================");
    console.log("\n[SS 链接]:");
    console.log(ssLink); 
    console.log("==================================================\n");
    
    fs.writeFileSync(subPath, Buffer.from(ssLink).toString('base64'));
  }, 3000);
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