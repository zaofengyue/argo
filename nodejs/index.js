/**
 * Argo - Zero-Binary 纯原生代理服务端
 */

const http = require('http');
const https = require('https');
const net = require('net');
const dns = require('dns');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
const { spawn, spawnSync, execSync } = require('child_process');

// ==================== 预留配置（留空则自动读取环境变量或默认值） ====================
// ── 1. 基础配置 ──
const PRESET_UUID              = ''; // 核心 UUID（留空默认读取环境变量 UUID，未设置则自动生成随机 UUID）
const PRESET_PASSWORD          = ''; // Trojan 密码（留空默认复用 UUID）
const PRESET_NAME              = ''; // 节点名称（留空默认自动识别 国家-运营商）
const PRESET_SUB               = ''; // 订阅路径后缀（默认 'sub'，即 /sub）

// ── 2. Argo 隧道配置 ──
const PRESET_ARGO_DOMAIN       = ''; // 固定隧道域名（留空使用临时隧道）
const PRESET_ARGO_AUTH         = ''; // 固定隧道 Token / 凭证
const PRESET_ARGO_PROTOCOL     = ''; // 连接协议（留空默认由 cloudflared 自动选择，可选：'http2'、'quic'）
const PRESET_CF_PREFER_HOST    = ''; // Cloudflare 优选域名/IP（默认 'www.visa.com.tw'）

// ── 3. Komari 监控探针配置 ──
const PRESET_KOMARI_DOMAIN     = ''; // Komari 服务端域名/地址（如 komari.example.com）
const PRESET_KOMARI_TOKEN      = ''; // Komari 探针密钥 Token

// ── 4. 日志与 Telegram 推送配置 ──
const PRESET_SHOW_LOG          = ''; // 是否在控制台打印订阅内容（默认 'true'）
const PRESET_LOG_CLEAR_MINUTES = ''; // 控制台显示配置后自动清理的等待时间（默认 '2' 分钟，'0' 为不清理）
const PRESET_TG_BOT_TOKEN      = ''; // Telegram Bot Token
const PRESET_TG_CHAT_ID        = ''; // Telegram Chat ID
// ==============================================================================

// ── 变量解析（优先读取 PRESET，其次读取环境变量，最后自动生成随机 UUID）──────────
const UUID            = (PRESET_UUID           || process.env.UUID            || crypto.randomUUID()).trim().toLowerCase();
const UUID_REGEX      = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
if (!UUID_REGEX.test(UUID)) {
  console.error(`[FATAL] 核心 UUID 格式无效: "${UUID}"！必须为标准的 32 位十六进制 UUID（例如: 8fce614c-83b5-442b-928d-c78278f2e2cb）`);
  process.exit(1);
}
const PASSWORD        = (PRESET_PASSWORD       || process.env.PASSWORD        || process.env.TROJAN_PASSWORD || UUID).trim();
const LISTEN_HOST     = (process.env.LISTEN_HOST || '0.0.0.0').trim();
const HOST            = LISTEN_HOST;
const PORT            = parseInt(process.env.PORT || '3000', 10);
const SUB_PATH        = (PRESET_SUB            || process.env.SUB             || 'sub').replace(/^\/+/, '');
let   NODE_NAME       = (PRESET_NAME           || process.env.NAME            || '').trim();

// Argo 隧道配置
const ARGO_DOMAIN     = (PRESET_ARGO_DOMAIN    || process.env.ARGO_DOMAIN     || '').trim();
const ARGO_AUTH       = (PRESET_ARGO_AUTH      || process.env.ARGO_AUTH       || '').trim();
const ARGO_PROTOCOL   = (PRESET_ARGO_PROTOCOL  || process.env.ARGO_PROTOCOL   || '').trim();
const CF_PREFER_HOST  = (PRESET_CF_PREFER_HOST || process.env.CF_PREFER_HOST  || process.env.CF_IP || 'www.visa.com.tw').trim();

// Komari 监控探针配置
const KOMARI_DOMAIN   = (PRESET_KOMARI_DOMAIN  || process.env.KOMARI_DOMAIN   || '').trim();
const KOMARI_TOKEN    = (PRESET_KOMARI_TOKEN   || process.env.KOMARI_TOKEN    || '').trim();

// 日志与推送配置
const SHOW_LOG        = (PRESET_SHOW_LOG          || process.env.SHOW_LOG          || 'true') === 'true';
const LOG_CLEAR_MIN   = parseInt(PRESET_LOG_CLEAR_MINUTES || process.env.LOG_CLEAR_MINUTES || '2', 10);
const TG_BOT_TOKEN    = (PRESET_TG_BOT_TOKEN      || process.env.TG_BOT_TOKEN      || '').trim();
const TG_CHAT_ID      = (PRESET_TG_CHAT_ID        || process.env.TG_CHAT_ID        || '').trim();

// ── 协议挂载路径（固定默认标准路径）─────────────────────────────────────────
const PATH_XHTTP        = '/vless-xhttp';
const PATH_VLESS        = '/vless-ws';
const PATH_TROJAN_XHTTP = '/trojan-xhttp';
const PATH_TROJAN       = '/trojan-ws';

// ── 全局运行与进程防杀状态 ───────────────────────────────────────────────────
const trackedProcesses = [];
let isShuttingDown = false;
let uptimeTimer = null;
let CURRENT_ARGO_HOST = ARGO_DOMAIN || 'your-domain.com';

const HOME_DIR = process.env.HOME || (os.platform() === 'win32' ? process.env.USERPROFILE : '/root');
const CORE_DIR = path.join(HOME_DIR, '.argo-core');
const SUB_FILE = path.join(process.cwd(), 'sub.txt');
const CF_BIN_PATH = path.join(CORE_DIR, os.platform() === 'win32' ? 'bridge.exe' : 'bridge');
const KM_BIN_PATH = path.join(CORE_DIR, os.platform() === 'win32' ? 'metrics.exe' : 'metrics');

// 进程伪装标签
const PROC_TAGS = ['node /app/bridge.js', 'node /app/metrics.js'];

function killStaleByTag(tags = PROC_TAGS) {
  if (os.platform() === 'win32') return;
  let uidArgs = [];
  try {
    if (typeof os.userInfo === 'function') {
      const uid = os.userInfo().uid;
      if (typeof uid === 'number') uidArgs = ['-u', String(uid)];
    }
  } catch {}
  for (const tag of tags) {
    try { spawnSync('pkill', [...uidArgs, '-f', tag], { stdio: 'ignore' }); } catch {}
  }
}

// ── 守护进程管理器（支持指数退避与自动重启保活）─────────────────────────────
function superviseProcess(name, spawnFn) {
  let delay = 3000;
  const launch = () => {
    if (isShuttingDown) return null;
    const startedAt = Date.now();
    const child = spawnFn();
    if (!child) return null;
    trackedProcesses.push(child);
    console.log(`[保活] ${name} 已启动 (PID: ${child.pid})`);

    child.on('error', (err) => console.error(`[保活] ${name} 启动失败: ${err.message}`));
    child.on('exit', (code, sig) => {
      const i = trackedProcesses.indexOf(child);
      if (i >= 0) trackedProcesses.splice(i, 1);
      if (isShuttingDown) return;
      delay = (Date.now() - startedAt > 60000) ? 3000 : Math.min(delay * 2, 60000);
      console.warn(`[保活] ${name} 异常退出 (code=${code}, sig=${sig})，${delay / 1000}s 后自动重启`);
      setTimeout(launch, delay).unref();
    });
    return child;
  };
  return launch();
}

// 防崩溃全局防护罩
process.on('uncaughtException', (err) => {
  console.error('[系统防崩溃] 拦截异常:', (err && err.stack) ? err.stack : err);
});
process.on('unhandledRejection', (reason) => {
  console.warn('[系统防崩溃] 拦截异步拒绝:', (reason && reason.stack) ? reason.stack : reason);
});

// ── 预编译鉴权哈希缓存 ────────────────────────────────────────────────────────
const UUID_BUF = Buffer.from(UUID.replace(/-/g, ''), 'hex');
const TROJAN_HASH_STR = crypto.createHash('sha224').update(PASSWORD).digest('hex');

// ── 读取伪装网页 ─────────────────────────────────────────────────────────────
const HTML_FILE = path.join(__dirname, 'index.html');
let CAMOUFLAGE_HTML = '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Service Active</h1></body></html>';
if (fs.existsSync(HTML_FILE)) {
  try { CAMOUFLAGE_HTML = fs.readFileSync(HTML_FILE, 'utf8'); } catch {}
}

// ── 节点名称地理与运营商探测（对标 sing-box 版）─────────────────────────────
function normalizeCountry(s) {
  s = String(s || '').trim().toUpperCase();
  return /^[A-Z]{2}$/.test(s) ? s : '';
}

function normalizeOrg(s) {
  return String(s || '')
    .replace(/^AS\d+\s+/, '')
    .replace(/,?\s*\b(Inc|LLC|Ltd|Corp)\b\.?/gi, '')
    .replace(/[^A-Za-z0-9 ._-]/g, '')
    .trim().substring(0, 20);
}

function httpGet(url, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const isHttps = url.startsWith('https');
    const client = isHttps ? https : http;
    const req = client.get(url, { timeout: timeoutMs }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return resolve(''); }
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve(data.trim()));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { req.destroy(); resolve(''); });
  });
}

async function resolveNodeName() {
  if (NODE_NAME) return NODE_NAME;
  try {
    const countryRaw = await httpGet('https://ipinfo.io/country') || await httpGet('https://ifconfig.co/country-iso');
    const orgRaw     = await httpGet('https://ipinfo.io/org')     || await httpGet('https://ifconfig.co/org');
    const country    = normalizeCountry(countryRaw);
    const org        = normalizeOrg(orgRaw);
    NODE_NAME = country && org ? `${country}-${org}` : country ? `${country}-argo` : 'argo';
  } catch {
    NODE_NAME = 'argo';
  }
  return NODE_NAME;
}

// ── 容器在线时长虚拟化（对标当前容器启动时刻，解决探针显示几百天问题）───────
function setupContainerUptime() {
  if (os.platform() !== 'linux' || uptimeTimer) return;
  const fakeFile = '/tmp/.fake_uptime';
  const startTime = Math.floor(Date.now() / 1000);
  try {
    fs.writeFileSync(fakeFile, '0.00 0.00\n');
    execSync(`mount --bind ${fakeFile} /proc/uptime`, { stdio: 'ignore' });
    uptimeTimer = setInterval(() => {
      const elapsed = Math.floor(Date.now() / 1000) - startTime;
      try {
        fs.writeFileSync(fakeFile + '.tmp', `${elapsed}.00 ${elapsed}.00\n`);
        fs.renameSync(fakeFile + '.tmp', fakeFile);
      } catch {}
    }, 2000);
    uptimeTimer.unref();
  } catch {}
}

// ── VLESS 二进制报文解析器（严格越界保护）─────────────────────────────────────
function parseVlessHeader(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 24) return null;
  if (buffer.readUInt8(0) !== 0) return null;
  if (!buffer.slice(1, 17).equals(UUID_BUF)) return null;

  let cursor = 17;
  const optLength = buffer.readUInt8(cursor);
  cursor += 1 + optLength;
  if (cursor + 3 > buffer.length) return null; // 需要 command (1B) + port (2B)

  const command = buffer.readUInt8(cursor);
  cursor += 1;
  if (command !== 1) return null; // 仅代理 TCP 流

  const targetPort = buffer.readUInt16BE(cursor);
  cursor += 2;

  if (cursor >= buffer.length) return null;
  const addrType = buffer.readUInt8(cursor);
  cursor += 1;

  let targetHost = '';
  if (addrType === 1) { // IPv4
    if (cursor + 4 > buffer.length) return null;
    targetHost = `${buffer[cursor]}.${buffer[cursor + 1]}.${buffer[cursor + 2]}.${buffer[cursor + 3]}`;
    cursor += 4;
  } else if (addrType === 2) { // 域名
    if (cursor + 1 > buffer.length) return null;
    const domainLen = buffer.readUInt8(cursor);
    cursor += 1;
    if (cursor + domainLen > buffer.length) return null;
    targetHost = buffer.slice(cursor, cursor + domainLen).toString('utf8');
    cursor += domainLen;
  } else if (addrType === 3) { // IPv6
    if (cursor + 16 > buffer.length) return null;
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(buffer.readUInt16BE(cursor + i * 2).toString(16));
    targetHost = parts.join(':');
    cursor += 16;
  } else {
    return null;
  }

  return {
    targetHost,
    targetPort,
    payload: buffer.length > cursor ? buffer.slice(cursor) : Buffer.alloc(0)
  };
}

// ── Trojan 二进制报文解析器（严格越界保护）───────────────────────────────────
function parseTrojanHeader(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 62) return null;
  const reqHash = buffer.slice(0, 56).toString('utf8');
  if (reqHash.toLowerCase() !== TROJAN_HASH_STR) return null;
  if (buffer[56] !== 0x0d || buffer[57] !== 0x0a) return null;
  if (buffer[58] !== 1) return null; // 仅代理 TCP 流

  const addrType = buffer[59];
  let cursor = 60, targetHost = '';
  if (addrType === 1) { // IPv4
    if (cursor + 4 > buffer.length) return null;
    targetHost = `${buffer[cursor]}.${buffer[cursor + 1]}.${buffer[cursor + 2]}.${buffer[cursor + 3]}`;
    cursor += 4;
  } else if (addrType === 3) { // 域名
    if (cursor + 1 > buffer.length) return null;
    const domainLen = buffer.readUInt8(cursor);
    cursor += 1;
    if (cursor + domainLen > buffer.length) return null;
    targetHost = buffer.slice(cursor, cursor + domainLen).toString('utf8');
    cursor += domainLen;
  } else if (addrType === 4) { // IPv6
    if (cursor + 16 > buffer.length) return null;
    const parts = [];
    for (let i = 0; i < 8; i++) parts.push(buffer.readUInt16BE(cursor + i * 2).toString(16));
    targetHost = parts.join(':');
    cursor += 16;
  } else {
    return null;
  }

  if (cursor + 4 > buffer.length) return null; // 2B port + 2B \r\n
  const targetPort = buffer.readUInt16BE(cursor);
  cursor += 2;
  if (buffer[cursor] !== 0x0d || buffer[cursor + 1] !== 0x0a) return null;
  cursor += 2;

  return {
    targetHost,
    targetPort,
    payload: buffer.length > cursor ? buffer.slice(cursor) : Buffer.alloc(0)
  };
}

// ── 节点链接生成器（原生高能组合，名称仅 国家+运营商）───────────────────
function generateNodeLinks(host, preferHost) {
  const remark = encodeURIComponent(NODE_NAME || 'argo');
  const vlessWs     = `vless://${UUID}@${preferHost}:443?encryption=none&security=tls&type=ws&host=${host}&path=${encodeURIComponent(PATH_VLESS)}&sni=${host}#${remark}`;
  const trojanWs    = `trojan://${PASSWORD}@${preferHost}:443?security=tls&type=ws&host=${host}&path=${encodeURIComponent(PATH_TROJAN)}&sni=${host}#${remark}`;

  // XHTTP (SplitHTTP) 仅在配置固定隧道 (ARGO_DOMAIN) 时激活生成
  if (!ARGO_DOMAIN) {
    return [vlessWs, trojanWs];
  }

  const vlessXhttp  = `vless://${UUID}@${preferHost}:443?encryption=none&security=tls&type=xhttp&host=${host}&path=${encodeURIComponent(PATH_XHTTP)}&mode=packet-up&sni=${host}#${remark}`;
  const trojanXhttp = `trojan://${PASSWORD}@${preferHost}:443?security=tls&type=xhttp&host=${host}&path=${encodeURIComponent(PATH_TROJAN_XHTTP)}&mode=packet-up&sni=${host}#${remark}`;

  return [vlessXhttp, vlessWs, trojanXhttp, trojanWs];
}

// ── 出站安全阻断名单 (基于 DNS 解析与网段判定，防 SSRF、回环及云厂商元数据劫持) ─
const ALLOW_LAN = process.env.ALLOW_LAN === 'true';
const blockList = new net.BlockList();

// 1. 本机回环、未指定与广播
blockList.addSubnet('0.0.0.0', 8);
blockList.addSubnet('127.0.0.0', 8);
blockList.addAddress('255.255.255.255');
blockList.addAddress('::', 'ipv6');
blockList.addAddress('::1', 'ipv6');
blockList.addSubnet('::ffff:127.0.0.0', 104, 'ipv6');

// 2. 链路本地 & 云厂商元数据 (AWS / Azure / GCP)
blockList.addSubnet('169.254.0.0', 16);
blockList.addSubnet('fe80::', 10, 'ipv6');

// 3. 运营商级 NAT (CGNAT) & 阿里云专用元数据 (100.100.100.200)
blockList.addSubnet('100.64.0.0', 10);

// 4. 私有局域网网段（默认阻断保护，设置 ALLOW_LAN=true 可按需放行家庭内网）
if (!ALLOW_LAN) {
  blockList.addSubnet('10.0.0.0', 8);
  blockList.addSubnet('172.16.0.0', 12);
  blockList.addSubnet('192.168.0.0', 16);
  blockList.addSubnet('fc00::', 7, 'ipv6');
}

// 5. 补充特异与保留网段 (NAT64, 6to4, 多播, 基准测试, TEST-NET, IETF保留)
blockList.addSubnet('64:ff9b::', 96, 'ipv6');
blockList.addSubnet('2002::', 16, 'ipv6');
blockList.addSubnet('224.0.0.0', 4);
blockList.addSubnet('ff00::', 8, 'ipv6');
blockList.addSubnet('198.18.0.0', 15);
blockList.addSubnet('192.0.0.0', 24);
blockList.addSubnet('192.0.2.0', 24);
blockList.addSubnet('198.51.100.0', 24);
blockList.addSubnet('203.0.113.0', 24);

function checkIpBlocked(ipStr, family = 'ipv4') {
  try {
    return blockList.check(ipStr, family);
  } catch {
    return true;
  }
}

function safeDnsLookup(hostname, options, callback) {
  dns.lookup(hostname, { all: true }, (err, addresses) => {
    if (err) return callback(err);
    if (!addresses || addresses.length === 0) {
      return callback(new Error(`DNS lookup empty for: ${hostname}`));
    }
    const safe = addresses.filter(a => !checkIpBlocked(a.address, a.family === 6 ? 'ipv6' : 'ipv4'));
    if (safe.length === 0) {
      return callback(new Error(`All resolved IPs blocked for: ${hostname}`));
    }
    if (options && options.all) {
      callback(null, safe);
    } else {
      callback(null, safe[0].address, safe[0].family);
    }
  });
}

function resolveAndConnect(targetHost, targetPort, onConnected, onError) {
  if (!targetHost) {
    if (onError) onError(new Error('Empty targetHost'));
    return null;
  }
  const h = targetHost.toLowerCase().trim().replace(/\.$/, '');
  if (h === 'localhost' || h.endsWith('.internal') || h.endsWith('.local')) {
    if (onError) onError(new Error(`Blocked host: ${targetHost}`));
    return null;
  }

  const isIp = net.isIP(h);
  if (isIp) {
    const family = isIp === 6 ? 'ipv6' : 'ipv4';
    if (checkIpBlocked(h, family)) {
      if (onError) onError(new Error(`Blocked IP: ${targetHost}`));
      return null;
    }
  }

  // 域名：安全 DNS 校验过滤，并开启 autoSelectFamily (RFC 8305 Happy Eyeballs 双栈自动回退)
  const connectOpts = isIp
    ? { host: h, port: targetPort }
    : { host: h, port: targetPort, lookup: safeDnsLookup, autoSelectFamily: true };

  const socket = net.connect(connectOpts);

  // 10 秒连接超时门禁，防止远端黑洞无限挂起
  const connTimer = setTimeout(() => {
    if (socket.connecting) {
      socket.destroy(new Error(`Connect timeout (10s) to ${targetHost}:${targetPort}`));
    }
  }, 10000);

  const initialErrorHandler = (err) => {
    clearTimeout(connTimer);
    socket.removeListener('error', initialErrorHandler);
    if (onError) onError(err);
  };
  socket.on('error', initialErrorHandler);

  socket.once('connect', () => {
    clearTimeout(connTimer);
    // 连接成功后立即卸载建连错误监听器，防止后续远端 RST 误触发建连失败与重复发头报错
    socket.removeListener('error', initialErrorHandler);
    if (onConnected) onConnected(socket);
  });

  socket.once('close', () => {
    clearTimeout(connTimer);
  });

  return socket;
}

// ── XHTTP (SplitHTTP) 会话多路复用连接池 (双层缓冲保护) ─────────────────────
const MAX_XHTTP_SESSIONS = 5000;
const xhttpSessions = new Map();
const UNAUTH_PER_SESSION_BYTES = 256 * 1024;       // 单个未认证会话最多允许暂存 256KB 乱序包（防 seq1 抢先于 seq0）
const UNAUTH_GLOBAL_BYTES      = 16 * 1024 * 1024;  // 全局所有未认证会话共享暂存上限 16MB（防 DoS 刷爆内存）
let unauthUplinkBytesGlobal    = 0;

function cleanupXhttpSession(sessionId) {
  const session = xhttpSessions.get(sessionId);
  if (!session) return;
  if (session.timer) clearTimeout(session.timer);
  if (session.unauthBufferedBytes > 0) {
    unauthUplinkBytesGlobal = Math.max(0, unauthUplinkBytesGlobal - session.unauthBufferedBytes);
    session.unauthBufferedBytes = 0;
  }
  if (session.remoteSocket && !session.remoteSocket.destroyed) {
    session.remoteSocket.destroy();
  }
  if (session.downlinkRes && !session.downlinkRes.writableEnded) {
    session.downlinkRes.end();
  }
  xhttpSessions.delete(sessionId);
}

function refreshSessionTimer(session) {
  // 未认证会话维持 15 秒固定超时，绝不因未认证的 GET/POST 刷新延长
  if (!session.isAuthenticated) return;
  if (session.timer) clearTimeout(session.timer);
  session.timer = setTimeout(() => cleanupXhttpSession(session.id), 60000);
}

function getOrCreateXhttpSession(sessionId, protocol = 'vless') {
  if (!sessionId || !/^[a-zA-Z0-9_-]{1,64}$/.test(sessionId)) {
    return null;
  }
  let session = xhttpSessions.get(sessionId);
  if (!session) {
    if (xhttpSessions.size >= MAX_XHTTP_SESSIONS) {
      // 双层保护：优先淘汰尚未完成认证（未收到有效握手）的空头/垃圾会话
      let evictedKey = null;
      for (const [key, s] of xhttpSessions.entries()) {
        if (!s.isAuthenticated) {
          evictedKey = key;
          break;
        }
      }
      if (!evictedKey) {
        evictedKey = xhttpSessions.keys().next().value;
      }
      if (evictedKey) cleanupXhttpSession(evictedKey);
    }
    session = {
      id: sessionId,
      protocol,
      remoteSocket: null,
      downlinkRes: null,
      uplinkQueue: [],
      downlinkQueue: [],
      nextUplinkSeq: 0,
      pendingUplinkMap: new Map(),
      pendingUplinkBytes: 0,
      unauthBufferedBytes: 0,
      isParsed: false,
      isConnected: false,
      isAuthenticated: false, // 收到正确密码的握手后才置为 true
      handshakeSent: false,
      headerBuf: Buffer.alloc(0),
      createdAt: Date.now(),
      timer: null
    };
    // 初始由 GET 创建的未认证会话给予 15 秒等待握手，超时自动销毁
    session.timer = setTimeout(() => {
      if (!session.isAuthenticated) cleanupXhttpSession(session.id);
    }, 15000);
    xhttpSessions.set(sessionId, session);
  }
  return session;
}

function dispatchUplinkData(session, data) {
  if (!session.isParsed) {
    session.headerBuf = Buffer.concat([session.headerBuf, data]);
    if (session.headerBuf.length > 2048) {
      cleanupXhttpSession(session.id);
      return;
    }
    const parsed = session.protocol === 'vless'
      ? parseVlessHeader(session.headerBuf)
      : parseTrojanHeader(session.headerBuf);

    if (parsed) {
      session.isParsed = true;
      session.isAuthenticated = true; // 认证通过！升级为正式活跃会话
      if (session.unauthBufferedBytes > 0) {
        unauthUplinkBytesGlobal = Math.max(0, unauthUplinkBytesGlobal - session.unauthBufferedBytes);
        session.unauthBufferedBytes = 0;
      }
      if (session.timer) clearTimeout(session.timer);
      session.timer = setTimeout(() => cleanupXhttpSession(session.id), 60000); // 切换为正常 60s 闲置超时

      resolveAndConnect(parsed.targetHost, parsed.targetPort, (remoteSocket) => {
        session.isConnected = true;
        if (session.protocol === 'vless' && session.downlinkRes && !session.handshakeSent) {
          session.downlinkRes.write(Buffer.from([0, 0]));
          session.handshakeSent = true;
        }
        if (parsed.payload.length > 0) {
          remoteSocket.write(parsed.payload);
        }
        if (session.uplinkQueue.length > 0) {
          for (const q of session.uplinkQueue) {
            remoteSocket.write(q);
          }
          session.uplinkQueue = [];
        }

        remoteSocket.on('data', (chunk) => {
          refreshSessionTimer(session);
          if (session.downlinkRes && !session.downlinkRes.writableEnded) {
            if (!session.downlinkRes.write(chunk)) {
              remoteSocket.pause();
            }
          } else {
            session.downlinkQueue.push(chunk);
          }
        });

        if (session.downlinkRes) {
          session.downlinkRes.on('drain', () => {
            if (remoteSocket && !remoteSocket.destroyed) remoteSocket.resume();
          });
        }

        remoteSocket.on('close', () => cleanupXhttpSession(session.id));
        remoteSocket.on('error', () => cleanupXhttpSession(session.id));
        session.remoteSocket = remoteSocket;
      }, () => {
        cleanupXhttpSession(session.id);
      });
    }
  } else {
    if (session.isConnected && session.remoteSocket && !session.remoteSocket.destroyed) {
      session.remoteSocket.write(data);
    } else {
      session.uplinkQueue.push(data);
    }
  }
}

function processXhttpUplinkData(session, data, seq = null) {
  if (session.isAuthenticated) refreshSessionTimer(session);
  if (seq === null) {
    dispatchUplinkData(session, data);
    return;
  }

  // 严格按 seq 序号保序消费，防止 CDN/HTTP2 并发乱序损坏数据流
  if (seq === session.nextUplinkSeq) {
    dispatchUplinkData(session, data);
    session.nextUplinkSeq++;

    while (session.pendingUplinkMap.has(session.nextUplinkSeq)) {
      const nextData = session.pendingUplinkMap.get(session.nextUplinkSeq);
      session.pendingUplinkMap.delete(session.nextUplinkSeq);
      session.pendingUplinkBytes = Math.max(0, session.pendingUplinkBytes - nextData.length);
      if (!session.isAuthenticated && session.unauthBufferedBytes > 0) {
        const dec = Math.min(session.unauthBufferedBytes, nextData.length);
        session.unauthBufferedBytes -= dec;
        unauthUplinkBytesGlobal = Math.max(0, unauthUplinkBytesGlobal - dec);
      }
      dispatchUplinkData(session, nextData);
      session.nextUplinkSeq++;
    }
  } else if (seq > session.nextUplinkSeq) {
    if (session.pendingUplinkMap.has(seq)) return; // 过滤重复 seq，防止缓冲计数器重复累加漂移
    if (!session.isAuthenticated) {
      // 未认证会话允许小额乱序缓冲（单会话 256KB，全局 16MB，15s 超时未认证自动释放）
      if (session.unauthBufferedBytes + data.length > UNAUTH_PER_SESSION_BYTES ||
          unauthUplinkBytesGlobal + data.length > UNAUTH_GLOBAL_BYTES) {
        return;
      }
      session.unauthBufferedBytes += data.length;
      unauthUplinkBytesGlobal += data.length;
    } else {
      // 已认证会话按总字节数限制（最大缓冲 4MB）
      if (session.pendingUplinkBytes + data.length > 4 * 1024 * 1024) {
        return;
      }
    }
    session.pendingUplinkMap.set(seq, data);
    session.pendingUplinkBytes += data.length;
  }
}

function handleXhttpSession(req, res, pathParts, protocol) {
  const sessionId = pathParts[1];
  const seqStr = pathParts[2];
  const seq = seqStr !== undefined && /^\d+$/.test(seqStr) ? parseInt(seqStr, 10) : null;
  const session = getOrCreateXhttpSession(sessionId, protocol);
  if (!session) {
    res.writeHead(400, { 'Content-Type': 'text/plain' });
    res.end('Bad Request');
    return;
  }
  if (session.isAuthenticated) refreshSessionTimer(session);

  if (req.method === 'GET') {
    session.downlinkRes = res;
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Transfer-Encoding': 'chunked',
      'Cache-Control': 'no-cache, no-store, no-transform',
      'Connection': 'keep-alive',
      'X-Accel-Buffering': 'no'
    });

    if (session.protocol === 'vless' && session.isConnected && !session.handshakeSent) {
      res.write(Buffer.from([0, 0]));
      session.handshakeSent = true;
    }

    if (session.downlinkQueue && session.downlinkQueue.length > 0) {
      for (const d of session.downlinkQueue) {
        res.write(d);
      }
      session.downlinkQueue = [];
    }

    res.on('drain', () => {
      if (session.remoteSocket && !session.remoteSocket.destroyed) {
        session.remoteSocket.resume();
      }
    });

    res.on('close', () => {
      cleanupXhttpSession(sessionId);
    });
    return;
  }

  if (req.method === 'POST') {
    let bodyLen = 0;
    const bodyChunks = [];
    req.on('data', (chunk) => {
      bodyLen += chunk.length;
      if (bodyLen > 2 * 1024 * 1024) {
        req.destroy();
        return;
      }
      bodyChunks.push(chunk);
    });
    req.on('end', () => {
      const data = Buffer.concat(bodyChunks);
      res.writeHead(200, {
        'Content-Type': 'text/plain',
        'Cache-Control': 'no-cache, no-store'
      });
      res.end('OK');

      if (data.length > 0) {
        processXhttpUplinkData(session, data, seq);
      }
    });
    req.on('error', () => cleanupXhttpSession(sessionId));
    return;
  }

  res.writeHead(405);
  res.end('Method Not Allowed');
}

// ── 1. HTTP 基础服务（Web 伪装、Base64 订阅与 xhttp 分块引擎）────────────────
const server = http.createServer((req, res) => {
  const reqUrl = req.url.split('?')[0];

  // ① 聚合节点订阅 (/sub)
  if (reqUrl === `/${SUB_PATH}` || reqUrl === `/${SUB_PATH}/`) {
    const host = CURRENT_ARGO_HOST;
    const prefer = CF_PREFER_HOST || host;
    const links = generateNodeLinks(host, prefer);
    const base64Content = Buffer.from(links.join('\n') + '\n').toString('base64');

    res.writeHead(200, {
      'Content-Type': 'text/plain; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0'
    });
    return res.end(base64Content);
  }

  const pathParts = reqUrl.split('/').filter(Boolean);
  const rootSegment = '/' + (pathParts[0] || '');

  // ② XHTTP (SplitHTTP) - 仅在配置固定隧道 (ARGO_DOMAIN) 时激活路由
  if (ARGO_DOMAIN) {
    // VLESS + xhttp
    if (rootSegment === PATH_XHTTP) {
      if (pathParts.length > 1) {
        return handleXhttpSession(req, res, pathParts, 'vless');
      }
      if (req.method === 'POST') {
        let isParsed = false;
        let remoteSocket = null;
        let pendingChunks = [];
        let pendingChunksBytes = 0;
        const MAX_PENDING_BYTES = 1024 * 1024;
        let isEnded = false;
        const chunksQueue = [];

        req.on('data', (chunk) => {
          if (!isParsed) {
            chunksQueue.push(chunk);
            const fullBuf = Buffer.concat(chunksQueue);

            if (fullBuf.length > 2048) {
              res.writeHead(400, { 'Content-Type': 'text/plain' });
              res.end('Bad Request');
              req.destroy();
              return;
            }

            const parsed = parseVlessHeader(fullBuf);
            if (parsed) {
              isParsed = true;
              const sock = resolveAndConnect(parsed.targetHost, parsed.targetPort, (connectedSock) => {
                res.writeHead(200, {
                  'Content-Type': 'application/octet-stream',
                  'Transfer-Encoding': 'chunked',
                  'Cache-Control': 'no-cache, no-store',
                  'Connection': 'keep-alive'
                });
                res.write(Buffer.from([0, 0])); // VLESS 握手响应
                if (parsed.payload.length > 0) connectedSock.write(parsed.payload);
                if (pendingChunks.length > 0) {
                  for (const b of pendingChunks) connectedSock.write(b);
                  pendingChunks = [];
                  pendingChunksBytes = 0;
                }
                if (isEnded && !connectedSock.destroyed) {
                  connectedSock.end();
                }

                connectedSock.on('data', (d) => {
                  if (!res.write(d)) {
                    connectedSock.pause();
                  }
                });
                res.on('drain', () => connectedSock.resume());
                connectedSock.on('close', () => res.end());
                connectedSock.on('error', () => res.end());
              }, () => {
                pendingChunks = [];
                pendingChunksBytes = 0;
                if (!res.headersSent) {
                  res.writeHead(403, { 'Content-Type': 'text/plain' });
                  res.end('Forbidden');
                } else {
                  res.end();
                }
                req.destroy();
              });
              remoteSocket = sock;
            }
          } else {
            if (remoteSocket && !remoteSocket.destroyed && !remoteSocket.connecting) {
              remoteSocket.write(chunk);
            } else {
              if (pendingChunksBytes + chunk.length <= MAX_PENDING_BYTES) {
                pendingChunks.push(chunk);
                pendingChunksBytes += chunk.length;
              } else {
                pendingChunks = [];
                pendingChunksBytes = 0;
                if (remoteSocket) remoteSocket.destroy();
                req.destroy(new Error('Pending buffer overflow (>1MB)'));
              }
            }
          }
        });

        req.on('end', () => {
          if (!isParsed) {
            res.writeHead(400, { 'Content-Type': 'text/plain' });
            res.end('Bad Request');
          } else {
            isEnded = true;
            if (remoteSocket && !remoteSocket.destroyed && !remoteSocket.connecting) {
              remoteSocket.end();
            }
          }
        });
        req.on('error', () => {
          pendingChunks = [];
          pendingChunksBytes = 0;
          if (remoteSocket) remoteSocket.destroy();
        });
        return;
      }
    }

    // Trojan + xhttp
    if (rootSegment === PATH_TROJAN_XHTTP) {
      if (pathParts.length > 1) {
        return handleXhttpSession(req, res, pathParts, 'trojan');
      }
      if (req.method === 'POST') {
        let isParsed = false;
        let remoteSocket = null;
        let pendingChunks = [];
        let pendingChunksBytes = 0;
        const MAX_PENDING_BYTES = 1024 * 1024;
        let isEnded = false;
        const chunksQueue = [];

        req.on('data', (chunk) => {
          if (!isParsed) {
            chunksQueue.push(chunk);
            const fullBuf = Buffer.concat(chunksQueue);

            if (fullBuf.length > 2048) {
              res.writeHead(400, { 'Content-Type': 'text/plain' });
              res.end('Bad Request');
              req.destroy();
              return;
            }

            const parsed = parseTrojanHeader(fullBuf);
            if (parsed) {
              isParsed = true;
              const sock = resolveAndConnect(parsed.targetHost, parsed.targetPort, (connectedSock) => {
                res.writeHead(200, {
                  'Content-Type': 'application/octet-stream',
                  'Transfer-Encoding': 'chunked',
                  'Cache-Control': 'no-cache, no-store',
                  'Connection': 'keep-alive'
                });
                if (parsed.payload.length > 0) connectedSock.write(parsed.payload);
                if (pendingChunks.length > 0) {
                  for (const b of pendingChunks) connectedSock.write(b);
                  pendingChunks = [];
                  pendingChunksBytes = 0;
                }
                if (isEnded && !connectedSock.destroyed) {
                  connectedSock.end();
                }

                connectedSock.on('data', (d) => {
                  if (!res.write(d)) {
                    connectedSock.pause();
                  }
                });
                res.on('drain', () => connectedSock.resume());
                connectedSock.on('close', () => res.end());
                connectedSock.on('error', () => res.end());
              }, () => {
                pendingChunks = [];
                pendingChunksBytes = 0;
                if (!res.headersSent) {
                  res.writeHead(403, { 'Content-Type': 'text/plain' });
                  res.end('Forbidden');
                } else {
                  res.end();
                }
                req.destroy();
              });
              remoteSocket = sock;
            }
          } else {
            if (remoteSocket && !remoteSocket.destroyed && !remoteSocket.connecting) {
              remoteSocket.write(chunk);
            } else {
              if (pendingChunksBytes + chunk.length <= MAX_PENDING_BYTES) {
                pendingChunks.push(chunk);
                pendingChunksBytes += chunk.length;
              } else {
                pendingChunks = [];
                pendingChunksBytes = 0;
                if (remoteSocket) remoteSocket.destroy();
                req.destroy(new Error('Pending buffer overflow (>1MB)'));
              }
            }
          }
        });

        req.on('end', () => {
          if (!isParsed) {
            res.writeHead(400, { 'Content-Type': 'text/plain' });
            res.end('Bad Request');
          } else {
            isEnded = true;
            if (remoteSocket && !remoteSocket.destroyed && !remoteSocket.connecting) {
              remoteSocket.end();
            }
          }
        });
        req.on('error', () => {
          pendingChunks = [];
          pendingChunksBytes = 0;
          if (remoteSocket) remoteSocket.destroy();
        });
        return;
      }
    }
  }

  // ④ 根路径展示静态海边日记伪装博客
  if (reqUrl === '/' || reqUrl === '/index.html') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(CAMOUFLAGE_HTML);
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

// ── 2. WebSocket 纯原生协议引擎（带背压流控与零拷贝管道）───────────────────
let WebSocket;
try {
  WebSocket = require('ws');
} catch (e) {
  console.warn('[Argo] 未检测到 ws 依赖，请在 nodejs 目录下运行 npm install');
}

if (WebSocket) {
  const wssVless  = new WebSocket.Server({ noServer: true });
  const wssTrojan = new WebSocket.Server({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    const reqUrl = req.url.split('?')[0];
    if (reqUrl === PATH_VLESS) {
      wssVless.handleUpgrade(req, socket, head, (ws) => wssVless.emit('connection', ws, req));
    } else if (reqUrl === PATH_TROJAN) {
      wssTrojan.handleUpgrade(req, socket, head, (ws) => wssTrojan.emit('connection', ws, req));
    } else {
      socket.destroy();
    }
  });

  // VLESS WS 处理
  wssVless.on('connection', (ws) => {
    let remoteSocket = null, isHeaderParsed = false, isWsClosed = false;
    let pendingChunks = [];
    let pendingChunksBytes = 0;
    const MAX_PENDING_BYTES = 1024 * 1024;

    const onEarlyDisconnect = () => {
      isWsClosed = true;
      pendingChunks = [];
      pendingChunksBytes = 0;
      if (remoteSocket && !remoteSocket.destroyed) remoteSocket.destroy();
    };
    ws.on('close', onEarlyDisconnect);
    ws.on('error', onEarlyDisconnect);

    ws.on('message', (chunk) => {
      if (isWsClosed) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (!isHeaderParsed) {
        const parsed = parseVlessHeader(buffer);
        if (!parsed) { ws.close(); return; }
        isHeaderParsed = true;
        const sock = resolveAndConnect(parsed.targetHost, parsed.targetPort, (connectedSock) => {
          if (isWsClosed || ws.readyState !== WebSocket.OPEN) {
            connectedSock.destroy();
            return;
          }
          ws.send(Buffer.from([0, 0]));
          if (parsed.payload.length > 0) connectedSock.write(parsed.payload);
          if (pendingChunks.length > 0) {
            for (const b of pendingChunks) connectedSock.write(b);
            pendingChunks = [];
            pendingChunksBytes = 0;
          }
          setupDuplexPipe(ws, connectedSock);
        }, () => {
          pendingChunks = [];
          pendingChunksBytes = 0;
          ws.close();
        });
        remoteSocket = sock;
      } else {
        if (remoteSocket && !remoteSocket.destroyed && !remoteSocket.connecting) {
          remoteSocket.write(buffer);
        } else {
          if (pendingChunksBytes + buffer.length <= MAX_PENDING_BYTES) {
            pendingChunks.push(buffer);
            pendingChunksBytes += buffer.length;
          } else {
            pendingChunks = [];
            pendingChunksBytes = 0;
            if (remoteSocket) remoteSocket.destroy();
            try { ws.close(1009, 'Message too big'); } catch {}
          }
        }
      }
    });
  });

  // Trojan WS 处理
  wssTrojan.on('connection', (ws) => {
    let remoteSocket = null, isHeaderParsed = false, isWsClosed = false;
    let pendingChunks = [];
    let pendingChunksBytes = 0;
    const MAX_PENDING_BYTES = 1024 * 1024;

    const onEarlyDisconnect = () => {
      isWsClosed = true;
      pendingChunks = [];
      pendingChunksBytes = 0;
      if (remoteSocket && !remoteSocket.destroyed) remoteSocket.destroy();
    };
    ws.on('close', onEarlyDisconnect);
    ws.on('error', onEarlyDisconnect);

    ws.on('message', (chunk) => {
      if (isWsClosed) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (!isHeaderParsed) {
        const parsed = parseTrojanHeader(buffer);
        if (!parsed) { ws.close(); return; }
        isHeaderParsed = true;
        const sock = resolveAndConnect(parsed.targetHost, parsed.targetPort, (connectedSock) => {
          if (isWsClosed || ws.readyState !== WebSocket.OPEN) {
            connectedSock.destroy();
            return;
          }
          if (parsed.payload.length > 0) connectedSock.write(parsed.payload);
          if (pendingChunks.length > 0) {
            for (const b of pendingChunks) connectedSock.write(b);
            pendingChunks = [];
            pendingChunksBytes = 0;
          }
          setupDuplexPipe(ws, connectedSock);
        }, () => {
          pendingChunks = [];
          pendingChunksBytes = 0;
          ws.close();
        });
        remoteSocket = sock;
      } else {
        if (remoteSocket && !remoteSocket.destroyed && !remoteSocket.connecting) {
          remoteSocket.write(buffer);
        } else {
          if (pendingChunksBytes + buffer.length <= MAX_PENDING_BYTES) {
            pendingChunks.push(buffer);
            pendingChunksBytes += buffer.length;
          } else {
            pendingChunks = [];
            pendingChunksBytes = 0;
            if (remoteSocket) remoteSocket.destroy();
            try { ws.close(1009, 'Message too big'); } catch {}
          }
        }
      }
    });
  });
}

function setupDuplexPipe(ws, remoteSocket) {
  // 事件驱动背压：利用 ws.send 完成回调驱动恢复，彻底移除 50ms 轮询定时器
  remoteSocket.on('data', (d) => {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(d, (err) => {
        if (err) {
          remoteSocket.destroy();
          return;
        }
        if (remoteSocket && !remoteSocket.destroyed && remoteSocket.isPaused()) {
          if (ws.bufferedAmount < 256 * 1024) {
            remoteSocket.resume();
          }
        }
      });
      if (ws.bufferedAmount > 1024 * 1024) {
        remoteSocket.pause();
      }
    }
  });

  const cleanup = () => {
    if (remoteSocket && !remoteSocket.destroyed) remoteSocket.destroy();
    if (ws.readyState === WebSocket.OPEN) ws.close();
  };

  remoteSocket.on('close', cleanup);
  remoteSocket.on('error', cleanup);
  ws.on('close', cleanup);
  ws.on('error', cleanup);
}

// ── 3. Telegram Bot 动态推送函数 ─────────────────────────────────────────────
function escapeHtml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function sendTelegramMessage(botToken, chatId, text) {
  return new Promise((resolve) => {
    if (!botToken || !chatId || !text) return resolve(false);
    const postData = JSON.stringify({
      chat_id: chatId,
      text: text,
      parse_mode: 'HTML',
      disable_web_page_preview: true
    });
    const options = {
      hostname: 'api.telegram.org',
      port: 443,
      path: `/bot${botToken}/sendMessage`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      },
      timeout: 10000
    };
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve(res.statusCode === 200));
    });
    req.on('error', (e) => {
      console.warn(`[Telegram] 推送异常: ${e.message}`);
      resolve(false);
    });
    req.write(postData);
    req.end();
  });
}

function notifyTelegram(host) {
  if (!TG_BOT_TOKEN || !TG_CHAT_ID) return;
  const prefer = CF_PREFER_HOST || host;
  const links = generateNodeLinks(host, prefer);
  const subUrl = `https://${host}/${SUB_PATH}`;

  const tgText = `🚀 <b>Argo 服务部署成功</b>\n\n` +
    `📌 <b>服务标识:</b> <code>${escapeHtml(NODE_NAME)}</code>\n` +
    `🌐 <b>订阅地址:</b> <code>${escapeHtml(subUrl)}</code>\n` +
    `🕒 <b>更新时间:</b> ${new Date().toLocaleString()}\n\n` +
    `📋 <b>连接链接:</b>\n<pre>${escapeHtml(links.join('\n\n'))}</pre>`;

  sendTelegramMessage(TG_BOT_TOKEN, TG_CHAT_ID, tgText).then((ok) => {
    if (ok) console.log('[Telegram] 节点配置已成功推送至 Telegram Bot');
  });
}

// ── 4. 订阅持久化、优雅展示与控制台自洁（对标 sing-box 版）─────────────
let subCleanScheduled = false;
function scheduleSubFileCleanup(delaySec) {
  if (subCleanScheduled || !fs.existsSync(SUB_FILE)) return;
  subCleanScheduled = true;
  if (os.platform() !== 'win32') {
    try {
      spawn('sh', ['-c', `sleep ${delaySec} && rm -f ${JSON.stringify(SUB_FILE)}`], {
        detached: true,
        stdio: 'ignore'
      }).unref();
      return;
    } catch {}
  }
  setTimeout(() => {
    try { if (fs.existsSync(SUB_FILE)) fs.unlinkSync(SUB_FILE); } catch {}
  }, delaySec * 1000).unref();
}

function writeSubFile(base64Content) {
  try {
    fs.writeFileSync(SUB_FILE, base64Content, { mode: 0o600 });
    if (os.platform() !== 'win32') {
      try { fs.chmodSync(SUB_FILE, 0o600); } catch {}
    }
  } catch {}
}

function displayNodeInfo(host) {
  const prefer = CF_PREFER_HOST || host;
  const links = generateNodeLinks(host, prefer);
  const base64Content = Buffer.from(links.join('\n') + '\n').toString('base64');
  const subUrl = `https://${host}/${SUB_PATH}`;

  // 1. 写入本地临时 sub.txt 文件 (Base64)
  writeSubFile(base64Content);

  // 2. 控制台展示 Base64 订阅内容与协议汇总
  if (SHOW_LOG) {
    console.log(`\n================= 🚀 订阅与节点配置 =================`);
    console.log(`📌 节点标识:  ${NODE_NAME}`);
    console.log(`🔑 核心 UUID: ${UUID}`);
    console.log(`🔒 独立密码:  ${PASSWORD}`);
    console.log(`📋 订阅地址:  ${subUrl}`);
    console.log(`📁 配置文件:  ${SUB_FILE}\n`);

    console.log(`================= 订阅内容 (Base64) =================`);
    console.log(base64Content);
    console.log(`====================================================\n`);

    console.log(`============== 已启用协议 ==============`);
    console.log(`✓ VLESS  + xhttp + Argo TLS`);
    console.log(`✓ VLESS  + WS    + Argo TLS`);
    console.log(`✓ Trojan + xhttp + Argo TLS`);
    console.log(`✓ Trojan + WS    + Argo TLS`);
    console.log(`========================================\n`);

    if (LOG_CLEAR_MIN > 0) {
      console.log(`⏳ 初始启动日志将在 ${LOG_CLEAR_MIN} 分钟后自动清空，sub.txt 将按策略自动释放...\n`);
      scheduleSubFileCleanup(LOG_CLEAR_MIN * 60);
      setTimeout(() => {
        try {
          console.clear();
          console.log(`====================================================`);
          console.log(`[系统提示] 初始化阶段已完成（已运行 ${LOG_CLEAR_MIN} 分钟），控制台已转入静默模式。`);
          console.log(`敏感配置与 sub.txt 已自动清理释放完毕，服务在后台持续稳定运行。`);
          console.log(`若需获取订阅链接，可访问订阅路径: ${subUrl}`);
          console.log(`====================================================`);
        } catch {}
      }, LOG_CLEAR_MIN * 60 * 1000).unref();
    }
  } else {
    console.log(`[系统提示] SHOW_LOG 已关闭，控制台保持静默运行。`);
    if (TG_BOT_TOKEN && TG_CHAT_ID) {
      scheduleSubFileCleanup(5); // TG 已推送，延时 5 秒释放临时文件
    } else {
      scheduleSubFileCleanup(120); // 未配 TG，2 分钟后自动清理
    }
  }
}

// ── 5. 通用下载工具（带 302 重定向跟随）───────────────────────────────────────
function downloadBinary(url, dest) {
  return new Promise((resolve, reject) => {
    const handleReq = (currUrl) => {
      https.get(currUrl, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          return handleReq(res.headers.location);
        }
        if (res.statusCode !== 200) {
          return reject(new Error(`HTTP ${res.statusCode}`));
        }
        const fileStream = fs.createWriteStream(dest);
        res.pipe(fileStream);
        fileStream.on('finish', () => {
          fileStream.close(() => {
            try { fs.chmodSync(dest, 0o755); } catch {}
            resolve(dest);
          });
        });
      }).on('error', reject);
    };
    handleReq(url);
  });
}

// ── 6. 辅助工具下载与完整性校验 ─────────────────────────────────────────────
function detectOS() {
  const s = os.platform();
  if (s === 'win32') return 'windows';
  if (s === 'darwin') return 'darwin';
  return 'linux';
}

function detectArch() {
  const m = os.arch();
  if (m === 'x64' || m === 'amd64') return 'amd64';
  if (m === 'arm64' || m === 'aarch64') return 'arm64';
  if (m === 'arm') return 'arm';
  return '386';
}

function verifyBinary(binPath, flag) {
  try {
    const out = spawnSync(binPath, [flag], { stdio: 'pipe', timeout: 3000 });
    return out.status === 0 || (out.stdout && out.stdout.length > 0) || (out.stderr && out.stderr.length > 0);
  } catch {
    return false;
  }
}

async function ensureCloudflared() {
  const candidates = [
    CF_BIN_PATH,
    'cloudflared',
    '/usr/local/bin/cloudflared',
    '/usr/bin/cloudflared',
    'C:\\cloudflared\\cloudflared.exe'
  ];
  for (const c of candidates) {
    try {
      if (fs.existsSync(c) && verifyBinary(c, '--version')) return c;
    } catch {}
  }

  const osType = detectOS();
  const arch = detectArch();
  const ext = osType === 'windows' ? '.exe' : '';
  const suffix = `${osType}-${arch}${ext}`;
  const url = `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${suffix}`;

  fs.mkdirSync(CORE_DIR, { recursive: true });
  console.log(`[Argo] 正在获取 cloudflared 穿透核心 (${suffix})...`);
  try {
    await downloadBinary(url, CF_BIN_PATH);
    if (!verifyBinary(CF_BIN_PATH, '--version')) {
      throw new Error('下载文件校验失败（损坏或不兼容）');
    }
    console.log('[Argo] cloudflared 准备就绪并通过验证');
    return CF_BIN_PATH;
  } catch (err) {
    console.warn(`[Argo] 自动下载 cloudflared 失败: ${err.message}`);
    try { fs.unlinkSync(CF_BIN_PATH); } catch {}
    return null;
  }
}

async function ensureKomariAgent() {
  if (!KOMARI_DOMAIN || !KOMARI_TOKEN) return null;
  const candidates = [
    KM_BIN_PATH,
    'komari-agent',
    '/usr/local/bin/komari-agent',
    '/root/.cache/node-core/node-metrics'
  ];
  for (const c of candidates) {
    try {
      if (fs.existsSync(c) && verifyBinary(c, '--help')) return c;
    } catch {}
  }

  const osType = detectOS();
  const arch = detectArch();
  if (arch !== 'amd64' && arch !== 'arm64') return null;

  const ext = osType === 'windows' ? '.exe' : '';
  const fileName = `komari-agent-${osType}-${arch}${ext}`;
  const url = `https://github.com/komari-monitor/komari-agent/releases/latest/download/${fileName}`;

  fs.mkdirSync(CORE_DIR, { recursive: true });
  console.log(`[Komari] 正在下载监控探针 (${fileName})...`);
  try {
    await downloadBinary(url, KM_BIN_PATH);
    if (!verifyBinary(KM_BIN_PATH, '--help')) {
      throw new Error('探针文件校验失败');
    }
    console.log('[Komari] 监控探针准备就绪并通过验证');
    return KM_BIN_PATH;
  } catch (err) {
    console.warn(`[Komari] 探针下载失败: ${err.message}`);
    try { fs.unlinkSync(KM_BIN_PATH); } catch {}
    return null;
  }
}

// ── 7. 启动 Argo 隧道（支持动态感知域名变更与守护保活）───────────────────────
async function startArgoTunnel(localPort) {
  const cfBin = await ensureCloudflared();
  if (!cfBin) {
    console.warn('[Argo] 未找到可用 cloudflared，跳过穿透');
    return;
  }

  const args = ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate'];
  if (ARGO_PROTOCOL && ARGO_PROTOCOL.toLowerCase() !== 'auto') {
    args.push('--protocol', ARGO_PROTOCOL);
  }

  const spawnOpts = {
    argv0: os.platform() !== 'win32' ? 'node /app/bridge.js' : undefined,
    stdio: ['ignore', 'ignore', 'pipe']
  };

  if (ARGO_DOMAIN && ARGO_AUTH) {
    console.log(`[Argo] 正在建立固定隧道: ${ARGO_DOMAIN} (协议: ${ARGO_PROTOCOL || 'auto'})`);
    args.push('run');
    CURRENT_ARGO_HOST = ARGO_DOMAIN;
    const cfEnv = { ...process.env, TUNNEL_TOKEN: ARGO_AUTH };

    superviseProcess('Argo固定隧道', () => {
      const proc = spawn(cfBin, args, {
        ...spawnOpts,
        env: cfEnv
      });
      let connLogged = false;
      proc.stderr.on('data', (chunk) => {
        const text = chunk.toString();
        const lines = text.split('\n');
        for (const rawLine of lines) {
          const line = rawLine.trim();
          if (!line) continue;
          if (/(Registered tunnel connection|Connection [a-z0-9-]+ registered)/i.test(line)) {
            if (!connLogged) {
              connLogged = true;
              console.log('[Argo固定隧道] 云端连接已就绪并注册成功');
            }
          } else if (/(ERR|error|fail|refused|unable|panic|fatal)/i.test(line)) {
            console.error(`[Argo固定隧道异常] ${line}`);
          }
        }
      });
      return proc;
    });

    setTimeout(() => {
      displayNodeInfo(CURRENT_ARGO_HOST);
      notifyTelegram(CURRENT_ARGO_HOST);
    }, 3000);
  } else {
    console.log(`[Argo] 正在向 Cloudflare 申请临时穿透域名... (协议: ${ARGO_PROTOCOL || 'auto'})`);
    args.push('--url', `http://127.0.0.1:${localPort}`);

    superviseProcess('Argo临时隧道', () => {
      const proc = spawn(cfBin, args, spawnOpts);
      proc.stderr.on('data', (data) => {
        const text = data.toString();
        const match = text.match(/https:\/\/(?!api\.)([a-z0-9-]+\.trycloudflare\.com)/);
        if (match && match[1] && match[1] !== CURRENT_ARGO_HOST) {
          CURRENT_ARGO_HOST = match[1];
          displayNodeInfo(CURRENT_ARGO_HOST);
          notifyTelegram(CURRENT_ARGO_HOST);
        }
        const lines = text.split('\n');
        for (const rawLine of lines) {
          const line = rawLine.trim();
          if (!line) continue;
          if (/(ERR|error|fail|refused|unable|panic|fatal)/i.test(line)) {
            console.error(`[Argo临时隧道异常] ${line}`);
          }
        }
      });
      return proc;
    });
  }
}

// ── 8. 启动 Komari 监控探针（守护保活）──────────────────────────────────────
async function startKomari() {
  if (!KOMARI_DOMAIN || !KOMARI_TOKEN) return;
  const kmBin = await ensureKomariAgent();
  if (!kmBin) return;

  setupContainerUptime();
  let endpoint = KOMARI_DOMAIN.trim();
  if (!/^https?:\/\//i.test(endpoint)) endpoint = `https://${endpoint}`;

  const args = ['--disable-auto-update', '--ignore-unsafe-cert'];
  const env = {
    ...process.env,
    KOMARI_SERVER: endpoint,
    KOMARI_TOKEN: KOMARI_TOKEN
  };

  console.log(`[Komari] 正在启动监控探针上报 (${endpoint})...`);
  superviseProcess('Komari监控探针', () => {
    return spawn(kmBin, args, {
      argv0: os.platform() !== 'win32' ? 'node /app/metrics.js' : undefined,
      stdio: 'ignore',
      env
    });
  });
}

// ── 9. 服务启动入口 ─────────────────────────────────────────────────────────
killStaleByTag();

const isDualStack = !LISTEN_HOST || LISTEN_HOST === '0.0.0.0' || LISTEN_HOST === '::' || LISTEN_HOST === '127.0.0.1' || LISTEN_HOST === 'localhost';

const onListening = async () => {
  await resolveNodeName();

  const listenAddr = isDualStack ? '0.0.0.0 / [::]' : HOST;
  console.log(`====================================================`);
  console.log(`🚀 Argo (Zero-Binary 纯原生穿透引擎) 已启动`);
  console.log(`📡 内部监听: ${listenAddr}:${PORT} (双栈兼容 localhost/127.0.0.1)`);
  console.log(`🏷️  节点标识: ${NODE_NAME}`);
  console.log(`🔑 核心 UUID: ${UUID}`);
  console.log(`🔒 独立密码: ${PASSWORD}`);
  console.log(`💾 内存占用: ${(process.memoryUsage().rss / 1024 / 1024).toFixed(2)} MB`);
  console.log(`====================================================`);

  startArgoTunnel(PORT);
  startKomari();
};

if (isDualStack) {
  let fallback = false;
  server.listen({ port: PORT, host: '::', ipv6Only: false }, onListening)
    .once('error', (err) => {
      if (!fallback && (err.code === 'EAFNOSUPPORT' || err.code === 'EADDRNOTAVAIL')) {
        fallback = true;
        console.log('[网络] 系统未启用 IPv6，自动降级至 IPv4 0.0.0.0 监听');
        server.listen(PORT, '0.0.0.0', onListening);
      } else {
        throw err;
      }
    });
} else {
  server.listen(PORT, HOST, onListening);
}

// ── 10. 优雅退出与孤儿清理 ───────────────────────────────────────────────────
function gracefulExit(sig) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`\n[安全退出] 收到 ${sig} 信号，正在清理子进程并释放资源...`);
  for (const proc of trackedProcesses) {
    try { if (proc && !proc.killed) proc.kill('SIGTERM'); } catch {}
  }
  killStaleByTag();
  if (uptimeTimer) {
    clearInterval(uptimeTimer);
    try { execSync('umount /proc/uptime', { stdio: 'ignore' }); } catch {}
    try { fs.unlinkSync('/tmp/.fake_uptime'); } catch {}
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 1000);
}
process.on('SIGINT', () => gracefulExit('SIGINT'));
process.on('SIGTERM', () => gracefulExit('SIGTERM'));
