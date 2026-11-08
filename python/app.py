"""
Argo - Zero-Binary 纯原生代理服务端
"""

import os
import sys
import re
import time
import base64
import hashlib
import hmac
import asyncio
import platform
import subprocess
import signal
import urllib.parse
import uuid
import socket
import ipaddress
import traceback
from pathlib import Path
from aiohttp import web, ClientSession, ClientTimeout, WSMsgType

# ==================== 预留配置（留空则自动读取环境变量或默认值） ====================
# ── 1. 基础配置 ──
PRESET_UUID              = '' # 核心 UUID（留空默认读取环境变量 UUID，未设置则自动生成随机 UUID）
PRESET_PASSWORD          = '' # Trojan 密码（留空默认复用 UUID）
PRESET_NAME              = '' # 节点名称（留空默认自动识别 国家-运营商）
PRESET_SUB               = '' # 订阅路径后缀（默认 'sub'，即 /sub）

# ── 2. Argo 隧道配置 ──
PRESET_ARGO_DOMAIN       = '' # 固定隧道域名（留空使用临时隧道）
PRESET_ARGO_AUTH         = '' # 固定隧道 Token / 凭证
PRESET_ARGO_PROTOCOL     = '' # 连接协议（留空默认自动选择，可选：'http2'、'quic'）
PRESET_CF_PREFER_HOST    = '' # Cloudflare 优选域名/IP（默认 'www.visa.com.tw'）

# ── 3. Komari 监控探针配置 ──
PRESET_KOMARI_DOMAIN     = '' # Komari 服务端域名/地址（如 komari.example.com）
PRESET_KOMARI_TOKEN      = '' # Komari 探针密钥 Token

# ── 4. 日志与 Telegram 推送配置 ──
PRESET_SHOW_LOG          = '' # 是否在控制台打印订阅内容（默认 'true'）
PRESET_LOG_CLEAR_MINUTES = '' # 控制台显示配置后自动清理的等待时间（默认 '2' 分钟，'0' 为不清理）
PRESET_TG_BOT_TOKEN      = '' # Telegram Bot Token
PRESET_TG_CHAT_ID        = '' # Telegram Chat ID
# ==============================================================================

# ── 变量解析（优先读取 PRESET，其次读取环境变量，最后自动生成随机 UUID）──────────
UUID            = (PRESET_UUID           or os.environ.get('UUID')            or str(uuid.uuid4())).strip().lower()
UUID_REGEX      = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.IGNORECASE)
if not UUID_REGEX.match(UUID):
    print(f"[FATAL] 核心 UUID 格式无效: \"{UUID}\"！必须为标准的 32 位十六进制 UUID（例如: 8fce614c-83b5-442b-928d-c78278f2e2cb）")
    sys.exit(1)
PASSWORD        = (PRESET_PASSWORD       or os.environ.get('PASSWORD')        or os.environ.get('TROJAN_PASSWORD') or UUID).strip()
LISTEN_HOST     = os.environ.get('LISTEN_HOST', '0.0.0.0').strip()
HOST            = LISTEN_HOST
PORT            = int(os.environ.get('PORT') or 3000)
SUB_PATH        = (PRESET_SUB            or os.environ.get('SUB')             or 'sub').lstrip('/')
NODE_NAME       = (PRESET_NAME           or os.environ.get('NAME')            or '').strip()

# Argo 隧道配置
ARGO_DOMAIN     = (PRESET_ARGO_DOMAIN    or os.environ.get('ARGO_DOMAIN')     or '').strip()
ARGO_AUTH       = (PRESET_ARGO_AUTH      or os.environ.get('ARGO_AUTH')       or '').strip()
ARGO_PROTOCOL   = (PRESET_ARGO_PROTOCOL  or os.environ.get('ARGO_PROTOCOL')   or '').strip()
CF_PREFER_HOST  = (PRESET_CF_PREFER_HOST or os.environ.get('CF_PREFER_HOST')  or os.environ.get('CF_IP') or 'www.visa.com.tw').strip()

# Komari 监控探针配置
KOMARI_DOMAIN   = (PRESET_KOMARI_DOMAIN  or os.environ.get('KOMARI_DOMAIN')   or '').strip()
KOMARI_TOKEN    = (PRESET_KOMARI_TOKEN   or os.environ.get('KOMARI_TOKEN')    or '').strip()

# 日志与推送配置
SHOW_LOG        = (PRESET_SHOW_LOG          or os.environ.get('SHOW_LOG')          or 'true').strip().lower() == 'true'
LOG_CLEAR_MIN   = int(PRESET_LOG_CLEAR_MINUTES or os.environ.get('LOG_CLEAR_MINUTES') or '2')
TG_BOT_TOKEN    = (PRESET_TG_BOT_TOKEN      or os.environ.get('TG_BOT_TOKEN')      or '').strip()
TG_CHAT_ID      = (PRESET_TG_CHAT_ID        or os.environ.get('TG_CHAT_ID')        or '').strip()

# ── 协议挂载路径（固定默认标准路径）─────────────────────────────────────────
PATH_XHTTP        = '/vless-xhttp'
PATH_VLESS        = '/vless-ws'
PATH_TROJAN_XHTTP = '/trojan-xhttp'
PATH_TROJAN       = '/trojan-ws'

# ── 全局运行与进程防杀状态 ───────────────────────────────────────────────────
tracked_processes = []
is_shutting_down = False
CURRENT_ARGO_HOST = ARGO_DOMAIN or 'your-domain.com'
node_name_task = None
background_tasks = set()

def track_task(task: asyncio.Task) -> asyncio.Task:
    background_tasks.add(task)
    task.add_done_callback(background_tasks.discard)
    return task

HOME_DIR = Path.home()
CORE_DIR = HOME_DIR / '.argo-core'
CORE_DIR.mkdir(parents=True, exist_ok=True)
SUB_FILE = Path.cwd() / 'sub.txt'

IS_WIN = platform.system().lower() == 'windows'
EXT = '.exe' if IS_WIN else ''
CF_BIN_PATH = CORE_DIR / f'bridge{EXT}'
KM_BIN_PATH = CORE_DIR / f'metrics{EXT}'

PROC_TAGS = ['python /app/bridge.py', 'python /app/metrics.py', 'node /app/bridge.js', 'node /app/metrics.js']

def kill_stale_by_tag(tags=PROC_TAGS):
    if IS_WIN:
        return
    uid_args = []
    try:
        uid = os.getuid()
        uid_args = ['-u', str(uid)]
    except Exception:
        pass
    for tag in tags:
        try:
            subprocess.run(['pkill', *uid_args, '-f', tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

# ── 守护进程管理器（异步指数退避与自动重启保活，对标 Node.js 版）─────────────
async def supervise_process(name: str, spawn_coro_fn):
    delay = 3.0
    while not is_shutting_down:
        started_at = time.time()
        proc = None
        try:
            proc = await spawn_coro_fn()
            if not proc:
                return
            tracked_processes.append(proc)
            print(f"[保活] {name} 已启动 (PID: {proc.pid})")
            code = await proc.wait()
            print(f"[保活] {name} 异常退出 (code={code})")
        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"[保活] {name} 运行异常: {e}")
        finally:
            if proc and proc in tracked_processes:
                tracked_processes.remove(proc)

        if is_shutting_down:
            break

        elapsed = time.time() - started_at
        delay = 3.0 if elapsed > 60 else min(delay * 2, 60.0)
        print(f"[保活] {name} 将在 {delay:.1f}s 后自动重启...")
        try:
            await asyncio.sleep(delay)
        except asyncio.CancelledError:
            break

# 全局防崩溃异常处理器
def handle_global_exception(loop, context):
    exc = context.get("exception")
    if exc:
        tb = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
        print(f"[系统防崩溃] 拦截异步异常:\n{tb.strip()}")
    else:
        msg = context.get("message", "未知异常")
        print(f"[系统防崩溃] 拦截异步异常: {msg}")

UUID_BYTES = bytes.fromhex(UUID.replace('-', ''))
TROJAN_HASH_STR = hashlib.sha224(PASSWORD.encode('utf-8')).hexdigest().lower()
TROJAN_HASH_BYTES = TROJAN_HASH_STR.encode('ascii')

HTML_FILE = Path(__file__).parent / 'index.html'
CAMOUFLAGE_HTML = '<!DOCTYPE html><html><head><title>Welcome</title></head><body><h1>Service Active</h1></body></html>'
if HTML_FILE.exists():
    try:
        CAMOUFLAGE_HTML = HTML_FILE.read_text(encoding='utf-8')
    except Exception:
        pass

# ── 节点名称地理与运营商探测（对标 sing-box 版）─────────────────────────────
def normalize_country(s: str) -> str:
    s = (s or '').strip().upper()
    return s if len(s) == 2 and s.isalpha() else ''

def normalize_org(s: str) -> str:
    s = s or ''
    s = re.sub(r'^AS\d+\s+', '', s)
    s = re.sub(r',?\s*\b(Inc|LLC|Ltd|Corp)\b\.?', '', s, flags=re.IGNORECASE)
    s = re.sub(r'[^A-Za-z0-9 ._-]', '', s)
    return s.strip()[:20]

async def http_get(url: str, timeout_sec: float = 3.0) -> str:
    try:
        timeout = ClientTimeout(total=timeout_sec)
        async with ClientSession(timeout=timeout) as session:
            async with session.get(url) as resp:
                if resp.status == 200:
                    text = await resp.text()
                    return text.strip()
    except Exception:
        pass
    return ''

async def resolve_node_name() -> str:
    global NODE_NAME
    if NODE_NAME:
        return NODE_NAME
    try:
        country_raw = await http_get('https://ipinfo.io/country') or await http_get('https://ifconfig.co/country-iso')
        org_raw     = await http_get('https://ipinfo.io/org')     or await http_get('https://ifconfig.co/org')
        c = normalize_country(country_raw)
        o = normalize_org(org_raw)
        NODE_NAME = f"{c}-{o}" if (c and o) else (f"{c}-argo" if c else "argo")
        if NODE_NAME and NODE_NAME != "argo":
            print(f"[节点标识] 归属地与运营商已识别: {NODE_NAME}")
    except Exception:
        NODE_NAME = "argo"
    return NODE_NAME

# ── 容器在线时长虚拟化（对标当前容器启动时刻，解决探针显示几百天问题）───────
def is_container_environment() -> bool:
    if platform.system().lower() != 'linux':
        return False
    try:
        if Path('/.dockerenv').exists() or Path('/run/.containerenv').exists():
            return True
        cgroup_path = Path('/proc/1/cgroup')
        if cgroup_path.exists():
            cgroup = cgroup_path.read_text('utf-8', errors='ignore')
            return bool(re.search(r'docker|kubepods|containerd|lxc', cgroup, re.I))
    except Exception:
        pass
    return False

async def setup_container_uptime():
    # 必须仅在真实容器环境下生效，严禁在 VPS 宿主机上篡改母机 /proc/uptime
    if not is_container_environment():
        return
    fake_file = Path('/tmp/.fake_uptime')
    start_time = int(time.time())
    try:
        fake_file.write_text('0.00 0.00\n')
        subprocess.run(['mount', '--bind', str(fake_file), '/proc/uptime'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while not is_shutting_down:
            await asyncio.sleep(2)
            elapsed = int(time.time()) - start_time
            fake_file.write_text(f'{elapsed}.00 {elapsed}.00\n')
    except Exception:
        pass

# ── VLESS 二进制报文解析器（严格越界保护与恒定时间防时序攻击）─────────────────
def parse_vless_header(buf: bytes):
    if not isinstance(buf, (bytes, bytearray)) or len(buf) < 24:
        return None
    if buf[0] != 0:
        return None
    if len(buf) < 17 or not hmac.compare_digest(buf[1:17], UUID_BYTES):
        return None

    cursor = 17
    opt_len = buf[cursor]
    cursor += 1 + opt_len
    if cursor + 3 > len(buf):
        return None

    command = buf[cursor]
    cursor += 1
    if command != 1: # 仅代理 TCP 流
        return None

    target_port = int.from_bytes(buf[cursor:cursor+2], 'big')
    cursor += 2

    if cursor >= len(buf):
        return None
    addr_type = buf[cursor]
    cursor += 1

    if addr_type == 1: # IPv4
        if cursor + 4 > len(buf):
            return None
        target_host = f"{buf[cursor]}.{buf[cursor+1]}.{buf[cursor+2]}.{buf[cursor+3]}"
        cursor += 4
    elif addr_type == 2: # 域名
        if cursor + 1 > len(buf):
            return None
        d_len = buf[cursor]
        cursor += 1
        if cursor + d_len > len(buf):
            return None
        target_host = buf[cursor:cursor+d_len].decode('utf-8', errors='ignore')
        cursor += d_len
    elif addr_type == 3: # IPv6
        if cursor + 16 > len(buf):
            return None
        parts = [f"{int.from_bytes(buf[cursor+i*2:cursor+(i+1)*2], 'big'):x}" for i in range(8)]
        target_host = ':'.join(parts)
        cursor += 16
    else:
        return None

    return {
        'target_host': target_host,
        'target_port': target_port,
        'payload': buf[cursor:]
    }

# ── Trojan 二进制报文解析器（严格越界保护与恒定时间防时序攻击）───────────────
def parse_trojan_header(buf: bytes):
    if not isinstance(buf, (bytes, bytearray)) or len(buf) < 62:
        return None
    req_hash = bytes(buf[:56]).lower()
    if not hmac.compare_digest(req_hash, TROJAN_HASH_BYTES):
        return None
    if buf[56] != 0x0D or buf[57] != 0x0A:
        return None
    if buf[58] != 1:
        return None

    addr_type = buf[59]
    cursor = 60
    if addr_type == 1: # IPv4
        if cursor + 4 > len(buf):
            return None
        target_host = f"{buf[cursor]}.{buf[cursor+1]}.{buf[cursor+2]}.{buf[cursor+3]}"
        cursor += 4
    elif addr_type == 3: # 域名
        if cursor + 1 > len(buf):
            return None
        d_len = buf[cursor]
        cursor += 1
        if cursor + d_len > len(buf):
            return None
        target_host = buf[cursor:cursor+d_len].decode('utf-8', errors='ignore')
        cursor += d_len
    elif addr_type == 4: # IPv6
        if cursor + 16 > len(buf):
            return None
        parts = [f"{int.from_bytes(buf[cursor+i*2:cursor+(i+1)*2], 'big'):x}" for i in range(8)]
        target_host = ':'.join(parts)
        cursor += 16
    else:
        return None

    if cursor + 4 > len(buf):
        return None
    target_port = int.from_bytes(buf[cursor:cursor+2], 'big')
    cursor += 2

    if buf[cursor] != 0x0D or buf[cursor+1] != 0x0A:
        return None
    cursor += 2

    return {
        'target_host': target_host,
        'target_port': target_port,
        'payload': buf[cursor:]
    }

# ── 节点链接生成器（原生高能组合，名称仅 国家+运营商）───────────────────
def generate_node_links(host: str, prefer_host: str) -> list[str]:
    remark = urllib.parse.quote(NODE_NAME or 'argo')
    path_vless = urllib.parse.quote(PATH_VLESS)
    path_trojan = urllib.parse.quote(PATH_TROJAN)

    vless_ws     = f"vless://{UUID}@{prefer_host}:443?encryption=none&security=tls&type=ws&host={host}&path={path_vless}&sni={host}#{remark}"
    trojan_ws    = f"trojan://{PASSWORD}@{prefer_host}:443?security=tls&type=ws&host={host}&path={path_trojan}&sni={host}#{remark}"

    # XHTTP (SplitHTTP) 仅在配置固定隧道 (ARGO_DOMAIN) 时激活生成
    if not ARGO_DOMAIN:
        return [vless_ws, trojan_ws]

    path_xhttp = urllib.parse.quote(PATH_XHTTP)
    path_trojan_xhttp = urllib.parse.quote(PATH_TROJAN_XHTTP)
    vless_xhttp  = f"vless://{UUID}@{prefer_host}:443?encryption=none&security=tls&type=xhttp&host={host}&path={path_xhttp}&mode=packet-up&sni={host}#{remark}"
    trojan_xhttp = f"trojan://{PASSWORD}@{prefer_host}:443?security=tls&type=xhttp&host={host}&path={path_trojan_xhttp}&mode=packet-up&sni={host}#{remark}"

    return [vless_xhttp, vless_ws, trojan_xhttp, trojan_ws]

# ── Telegram 推送函数 ────────────────────────────────────────────────────────
def escape_html(s: str) -> str:
    return str(s or '').replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')

async def send_telegram_message(bot_token: str, chat_id: str, text: str) -> bool:
    if not bot_token or not chat_id or not text:
        return False
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        'chat_id': chat_id,
        'text': text,
        'parse_mode': 'HTML',
        'disable_web_page_preview': True
    }
    try:
        timeout = ClientTimeout(total=10)
        async with ClientSession(timeout=timeout) as session:
            async with session.post(url, json=payload) as resp:
                return resp.status == 200
    except Exception as e:
        print(f"[Telegram] 推送异常: {e}")
        return False

async def notify_telegram(host: str):
    if not TG_BOT_TOKEN or not TG_CHAT_ID:
        return
    prefer = CF_PREFER_HOST or host
    links = generate_node_links(host, prefer)
    sub_url = f"https://{host}/{SUB_PATH}"

    tg_text = (
        f"🚀 <b>Argo 服务部署成功</b>\n\n"
        f"📌 <b>服务标识:</b> <code>{escape_html(NODE_NAME)}</code>\n"
        f"🌐 <b>订阅地址:</b> <code>{escape_html(sub_url)}</code>\n"
        f"🕒 <b>更新时间:</b> {time.strftime('%Y-%m-%d %H:%M:%S')}\n\n"
        f"📋 <b>连接链接:</b>\n<pre>{escape_html(chr(10).join(links))}</pre>"
    )
    ok = await send_telegram_message(TG_BOT_TOKEN, TG_CHAT_ID, tg_text)
    if ok:
        print("[Telegram] 节点配置已成功推送至 Telegram Bot")

# ── 订阅持久化与展示控制 ─────────────────────────────────────────────────────
sub_clean_scheduled = False

def write_sub_file(b64_content: str):
    try:
        SUB_FILE.write_text(b64_content, encoding='utf-8')
        if not IS_WIN:
            SUB_FILE.chmod(0o600)
    except Exception:
        pass

def schedule_sub_cleanup(delay_sec: int):
    global sub_clean_scheduled
    if sub_clean_scheduled or not SUB_FILE.exists():
        return
    sub_clean_scheduled = True

    async def cleanup():
        await asyncio.sleep(delay_sec)
        try:
            if SUB_FILE.exists():
                SUB_FILE.unlink(missing_ok=True)
        except Exception:
            pass

    try:
        track_task(asyncio.create_task(cleanup()))
    except RuntimeError:
        pass

def display_node_info(host: str):
    prefer = CF_PREFER_HOST or host
    links = generate_node_links(host, prefer)
    b64_content = base64.b64encode(('\n'.join(links) + '\n').encode('utf-8')).decode('utf-8')
    sub_url = f"https://{host}/{SUB_PATH}"

    write_sub_file(b64_content)

    if SHOW_LOG:
        print(f"\n================= 🚀 订阅与节点配置 =================")
        print(f"📌 节点标识:  {NODE_NAME}")
        print(f"🔑 核心 UUID: {UUID}")
        print(f"🔒 独立密码:  {PASSWORD}")
        print(f"📋 订阅地址:  {sub_url}")
        print(f"📁 配置文件:  {SUB_FILE}\n")

        print(f"================= 订阅内容 (Base64) =================")
        print(b64_content)
        print(f"====================================================\n")

        print(f"============== 已启用协议 ==============")
        if ARGO_DOMAIN:
            print(f"✓ VLESS  + xhttp + Argo TLS")
        print(f"✓ VLESS  + WS    + Argo TLS")
        if ARGO_DOMAIN:
            print(f"✓ Trojan + xhttp + Argo TLS")
        print(f"✓ Trojan + WS    + Argo TLS")
        print(f"========================================\n")

        if LOG_CLEAR_MIN > 0:
            print(f"⏳ 初始启动日志将在 {LOG_CLEAR_MIN} 分钟后自动清空，sub.txt 将按策略自动释放...\n")
            schedule_sub_cleanup(LOG_CLEAR_MIN * 60)
            async def clear_task():
                await asyncio.sleep(LOG_CLEAR_MIN * 60)
                os.system('cls' if IS_WIN else 'clear')
                print("====================================================")
                print(f"[系统提示] 初始化阶段已完成（已运行 {LOG_CLEAR_MIN} 分钟），控制台已转入静默模式。")
                print("敏感配置与 sub.txt 已自动清理释放完毕，服务在后台持续稳定运行。")
                print(f"若需获取订阅链接，可访问订阅路径: {sub_url}")
                print("====================================================")
            try:
                track_task(asyncio.create_task(clear_task()))
            except RuntimeError:
                pass
    else:
        print("[系统提示] SHOW_LOG 已关闭，控制台保持静默运行。")
        if TG_BOT_TOKEN and TG_CHAT_ID:
            schedule_sub_cleanup(5)
        else:
            schedule_sub_cleanup(120)

# ── 辅助工具下载与完整性校验 ─────────────────────────────────────────────
def detect_os():
    s = platform.system().lower()
    return 'windows' if 'win' in s else ('darwin' if 'darwin' in s else 'linux')

def detect_arch():
    m = platform.machine().lower()
    if m in ['x86_64', 'amd64']:
        return 'amd64'
    if m in ['aarch64', 'arm64']:
        return 'arm64'
    if 'arm' in m:
        return 'arm'
    return '386'

def verify_binary(bin_path: Path, flag: str) -> bool:
    try:
        res = subprocess.run([str(bin_path), flag], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
        return res.returncode == 0 or len(res.stdout) > 0 or len(res.stderr) > 0
    except Exception:
        return False

async def download_binary(url: str, dest: Path) -> Path:
    timeout = ClientTimeout(total=120)
    headers = {
        'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*'
    }
    async with ClientSession(timeout=timeout, headers=headers) as session:
        async with session.get(url, allow_redirects=True) as resp:
            if resp.status != 200:
                raise RuntimeError(f"HTTP {resp.status}")
            with open(dest, 'wb') as f:
                while True:
                    chunk = await resp.content.read(65536)
                    if not chunk:
                        break
                    f.write(chunk)
    dest.chmod(0o755)
    return dest

async def ensure_cloudflared() -> Path | None:
    candidates = [
        CF_BIN_PATH,
        Path('/root/.argo-core/bridge'),
        Path('/opt/argo-core/bridge'),
        Path('cloudflared'),
        Path('/usr/local/bin/cloudflared'),
        Path('/usr/bin/cloudflared')
    ]
    for c in candidates:
        if c.exists() and verify_binary(c, '--version'):
            return c

    os_type = detect_os()
    arch = detect_arch()
    suffix = f"{os_type}-{arch}{EXT}"
    base_suffix = f"cloudflared-{suffix}"
    urls = [
        f"https://github.com/cloudflare/cloudflared/releases/latest/download/{base_suffix}",
        f"https://ghfast.top/https://github.com/cloudflare/cloudflared/releases/latest/download/{base_suffix}",
        f"https://ghproxy.net/https://github.com/cloudflare/cloudflared/releases/latest/download/{base_suffix}"
    ]

    print(f"[Argo] 正在获取 cloudflared 穿透核心 ({suffix})...")
    for u in urls:
        try:
            await download_binary(u, CF_BIN_PATH)
            if verify_binary(CF_BIN_PATH, '--version'):
                print("[Argo] cloudflared 准备就绪并通过验证")
                return CF_BIN_PATH
            if CF_BIN_PATH.exists():
                CF_BIN_PATH.unlink(missing_ok=True)
        except Exception as e:
            host = 'mirror'
            try:
                host = urllib.parse.urlparse(u).netloc
            except Exception:
                pass
            print(f"[Argo] 从源 {host} 下载 cloudflared 失败: {e}")
            if CF_BIN_PATH.exists():
                CF_BIN_PATH.unlink(missing_ok=True)
    return None

async def ensure_komari_agent() -> Path | None:
    if not KOMARI_DOMAIN or not KOMARI_TOKEN:
        return None
    candidates = [
        KM_BIN_PATH,
        Path('/opt/argo-core/metrics'),
        Path('komari-agent'),
        Path('/usr/local/bin/komari-agent'),
        Path.home() / '.cache/node-core/node-metrics'
    ]
    for c in candidates:
        if c.exists() and verify_binary(c, '--help'):
            return c

    os_type = detect_os()
    arch = detect_arch()
    if arch not in ['amd64', 'arm64']:
        return None

    filename = f"komari-agent-{os_type}-{arch}{EXT}"
    urls = [
        f"https://github.com/komari-monitor/komari-agent/releases/latest/download/{filename}",
        f"https://ghfast.top/https://github.com/komari-monitor/komari-agent/releases/latest/download/{filename}",
        f"https://ghproxy.net/https://github.com/komari-monitor/komari-agent/releases/latest/download/{filename}"
    ]

    print(f"[Komari] 正在下载监控探针 ({filename})...")
    for u in urls:
        try:
            await download_binary(u, KM_BIN_PATH)
            if verify_binary(KM_BIN_PATH, '--help'):
                print("[Komari] 监控探针准备就绪并通过验证")
                return KM_BIN_PATH
            if KM_BIN_PATH.exists():
                KM_BIN_PATH.unlink(missing_ok=True)
        except Exception as e:
            host = 'mirror'
            try:
                host = urllib.parse.urlparse(u).netloc
            except Exception:
                pass
            print(f"[Komari] 从源 {host} 下载探针失败: {e}")
            if KM_BIN_PATH.exists():
                KM_BIN_PATH.unlink(missing_ok=True)
    return None

# ── 启动 Argo 隧道（异步进程守护 + 原生无线程域名监听）───────────────────────
async def start_argo_tunnel(local_port: int):
    global CURRENT_ARGO_HOST
    cf_bin = await ensure_cloudflared()
    if not cf_bin:
        print("[Argo] 未找到可用 cloudflared，跳过穿透")
        return

    args = ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate']
    if ARGO_PROTOCOL and ARGO_PROTOCOL.lower() != 'auto':
        args.extend(['--protocol', ARGO_PROTOCOL])

    if ARGO_DOMAIN and ARGO_AUTH:
        print(f"[Argo] 正在建立固定隧道: {ARGO_DOMAIN} (协议: {ARGO_PROTOCOL or 'auto'})")
        fixed_args = list(args) + ['run']
        CURRENT_ARGO_HOST = ARGO_DOMAIN
        env = os.environ.copy()
        env['TUNNEL_TOKEN'] = ARGO_AUTH

        notified = False
        fallback_task = None

        async def trigger_success():
            nonlocal notified, fallback_task
            if notified:
                return
            notified = True
            if fallback_task and not fallback_task.done() and asyncio.current_task() != fallback_task:
                fallback_task.cancel()
            global node_name_task
            if node_name_task and not node_name_task.done():
                try:
                    await asyncio.wait_for(asyncio.shield(node_name_task), timeout=5.0)
                except Exception:
                    pass
            display_node_info(CURRENT_ARGO_HOST)
            await notify_telegram(CURRENT_ARGO_HOST)

        async def fallback_timer():
            try:
                await asyncio.sleep(30)
                if not notified:
                    print("[Argo固定隧道] 等待云端注册信号超时 (30s)，先行呈现配置（请检查 Token 与网络状态）", file=sys.stderr)
                    await trigger_success()
            except asyncio.CancelledError:
                pass

        fallback_task = asyncio.create_task(fallback_timer())

        async def spawn_fixed():
            proc = await asyncio.create_subprocess_exec(
                str(cf_bin), *fixed_args,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE,
                env=env
            )

            async def monitor_fixed_stderr():
                conn_logged = False
                while not is_shutting_down:
                    line = await proc.stderr.readline()
                    if not line:
                        break
                    line_str = line.decode('utf-8', errors='ignore').strip()
                    if not line_str:
                        continue
                    if re.search(r'(Registered tunnel connection|Connection [a-z0-9-]+ registered)', line_str, re.I):
                        if not conn_logged:
                            conn_logged = True
                            print("[Argo固定隧道] 云端连接已就绪并注册成功")
                            await trigger_success()
                    elif not re.search(r'(\bINF\b|hard_fail=false)', line_str, re.I) and re.search(r'(ERR|error|\bfail(ed|ure)?\b|refused|unable|panic|fatal)', line_str, re.I):
                        print(f"[Argo固定隧道异常] {line_str}", file=sys.stderr)

            track_task(asyncio.create_task(monitor_fixed_stderr()))
            return proc

        track_task(asyncio.create_task(supervise_process('Argo固定隧道', spawn_fixed)))
    else:
        print(f"[Argo] 正在向 Cloudflare 申请临时穿透域名... (协议: {ARGO_PROTOCOL or 'auto'})")
        temp_args = list(args) + ['--url', f"http://127.0.0.1:{local_port}"]

        async def spawn_temp():
            proc = await asyncio.create_subprocess_exec(
                str(cf_bin), *temp_args,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.PIPE
            )

            async def monitor_stderr():
                global CURRENT_ARGO_HOST
                while not is_shutting_down:
                    line = await proc.stderr.readline()
                    if not line:
                        break
                    line_str = line.decode('utf-8', errors='ignore').strip()
                    if not line_str:
                        continue
                    match = re.search(r'https://(?!api\.)([a-z0-9-]+\.trycloudflare\.com)', line_str)
                    if match:
                        new_host = match.group(1)
                        if new_host != CURRENT_ARGO_HOST:
                            CURRENT_ARGO_HOST = new_host
                            global node_name_task
                            if node_name_task and not node_name_task.done():
                                try:
                                    await asyncio.wait_for(asyncio.shield(node_name_task), timeout=5.0)
                                except Exception:
                                    pass
                            display_node_info(CURRENT_ARGO_HOST)
                            await notify_telegram(CURRENT_ARGO_HOST)
                    elif not re.search(r'(\bINF\b|hard_fail=false)', line_str, re.I) and re.search(r'(ERR|error|\bfail(ed|ure)?\b|refused|unable|panic|fatal)', line_str, re.I):
                        print(f"[Argo临时隧道异常] {line_str}", file=sys.stderr)

            track_task(asyncio.create_task(monitor_stderr()))
            return proc

        track_task(asyncio.create_task(supervise_process('Argo临时隧道', spawn_temp)))

# ── 启动 Komari 监控探针（异步进程守护保活）──────────────────────────────────
async def start_komari():
    if not KOMARI_DOMAIN or not KOMARI_TOKEN:
        return
    km_bin = await ensure_komari_agent()
    if not km_bin:
        return

    track_task(asyncio.create_task(setup_container_uptime()))
    endpoint = KOMARI_DOMAIN.strip()
    if not endpoint.startswith(('http://', 'https://')):
        endpoint = f"https://{endpoint}"

    args = ['--disable-auto-update', '--ignore-unsafe-cert']
    env = os.environ.copy()
    env['KOMARI_SERVER'] = endpoint
    env['KOMARI_TOKEN'] = KOMARI_TOKEN

    print(f"[Komari] 正在启动监控探针上报 ({endpoint})...")

    async def spawn_km():
        return await asyncio.create_subprocess_exec(
            str(km_bin), *args,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            env=env
        )

    track_task(asyncio.create_task(supervise_process('Komari监控探针', spawn_km)))

# ── 路由与全双工转发引擎 ───────────────────────────────────────────────────
routes = web.RouteTableDef()

@routes.get('/')
@routes.get('/index.html')
async def handle_index(request):
    return web.Response(text=CAMOUFLAGE_HTML, content_type='text/html')

@routes.get(f'/{SUB_PATH}')
@routes.get(f'/{SUB_PATH}/')
async def handle_sub(request):
    host = CURRENT_ARGO_HOST
    if host == 'your-domain.com':
        req_host = request.headers.get('Host', '').split(':')[0].strip()
        if req_host:
            host = req_host
    prefer = CF_PREFER_HOST or host
    links = generate_node_links(host, prefer)
    content = base64.b64encode(('\n'.join(links) + '\n').encode('utf-8')).decode('utf-8')
    return web.Response(
        text=content,
        content_type='text/plain',
        charset='utf-8',
        headers={'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0'}
    )

# ── 出站安全阻断名单 (基于 DNS 解析与网段判定，防 SSRF、回环及云厂商元数据劫持) ─
ALLOW_LAN = os.environ.get('ALLOW_LAN', '').strip().lower() in ('true', '1', 'yes')

BLOCKED_NETWORKS = [
    ipaddress.ip_network('0.0.0.0/8'),
    ipaddress.ip_network('127.0.0.0/8'),
    ipaddress.ip_network('169.254.0.0/16'),
    ipaddress.ip_network('100.64.0.0/10'),
    ipaddress.ip_network('64:ff9b::/96'),
    ipaddress.ip_network('2002::/16'),
    ipaddress.ip_network('198.18.0.0/15'),
    ipaddress.ip_network('192.0.0.0/24'),
    ipaddress.ip_network('192.0.2.0/24'),
    ipaddress.ip_network('198.51.100.0/24'),
    ipaddress.ip_network('203.0.113.0/24'),
]
if not ALLOW_LAN:
    BLOCKED_NETWORKS.extend([
        ipaddress.ip_network('10.0.0.0/8'),
        ipaddress.ip_network('172.16.0.0/12'),
        ipaddress.ip_network('192.168.0.0/16'),
        ipaddress.ip_network('fc00::/7'),
    ])

def is_ip_blocked(ip_obj) -> bool:
    # 归一化 IPv4-mapped IPv6 地址 (如 ::ffff:10.0.0.1 -> 10.0.0.1)
    if ip_obj.version == 6 and ip_obj.ipv4_mapped:
        ip_obj = ip_obj.ipv4_mapped

    if ip_obj.is_multicast or ip_obj.is_unspecified or ip_obj.is_loopback or ip_obj.is_link_local or ip_obj.is_reserved:
        return True

    for net_range in BLOCKED_NETWORKS:
        if ip_obj in net_range:
            return True
    return False

def configure_socket_keepalive(writer):
    if not writer:
        return
    try:
        sock = writer.get_extra_info('socket')
        if sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except Exception:
        pass

async def safe_open_connection(target_host: str, target_port: int):
    if not target_host:
        return None, None
    h = target_host.lower().strip().rstrip('.')
    if h == 'localhost' or h.endswith('.internal') or h.endswith('.local'):
        return None, None

    # 字面量 IP 直接校验
    try:
        ip_obj = ipaddress.ip_address(h)
        if is_ip_blocked(ip_obj):
            return None, None
        r_reader, r_writer = await asyncio.wait_for(asyncio.open_connection(str(ip_obj), target_port), timeout=10.0)
        configure_socket_keepalive(r_writer)
        return r_reader, r_writer
    except ValueError:
        pass
    except Exception:
        return None, None

    # 域名 DNS 解析并按顺序尝试（安全过滤 + RFC 8305 Happy Eyeballs 双栈回退，每地址 5s 超时）
    loop = asyncio.get_running_loop()
    try:
        infos = await loop.getaddrinfo(h, target_port, family=socket.AF_UNSPEC, type=socket.SOCK_STREAM)
    except Exception:
        return None, None

    safe_addrs = []
    for family, type_, proto, canonname, sockaddr in infos:
        try:
            ip_obj = ipaddress.ip_address(sockaddr[0])
            if not is_ip_blocked(ip_obj):
                safe_addrs.append(sockaddr)
        except ValueError:
            continue

    if not safe_addrs:
        return None, None

    for sockaddr in safe_addrs:
        try:
            r_reader, r_writer = await asyncio.wait_for(asyncio.open_connection(sockaddr[0], sockaddr[1]), timeout=5.0)
            configure_socket_keepalive(r_writer)
            return r_reader, r_writer
        except Exception:
            continue

    return None, None

# ── XHTTP (SplitHTTP) 会话多路复用连接池 (双层缓冲保护架构) ─────────────────
MAX_XHTTP_SESSIONS = 5000
xhttp_sessions: dict[str, dict] = {}
UNAUTH_PER_SESSION_BYTES = 256 * 1024        # 单个未认证会话最多允许暂存 256KB 乱序包（防 seq1 抢先于 seq0）
UNAUTH_GLOBAL_BYTES      = 16 * 1024 * 1024   # 全局所有未认证会话共享暂存上限 16MB（防 DoS 刷爆内存）
unauth_uplink_bytes_global = 0

def get_or_create_xhttp_session(session_id: str, protocol: str = 'vless'):
    if not session_id or not re.match(r'^[a-zA-Z0-9_-]{1,64}$', session_id):
        return None
    sess = xhttp_sessions.get(session_id)
    if not sess:
        if len(xhttp_sessions) >= MAX_XHTTP_SESSIONS:
            evicted_id = None
            for sid, s in xhttp_sessions.items():
                if not s.get('is_authenticated'):
                    evicted_id = sid
                    break
            if not evicted_id:
                evicted_id = next(iter(xhttp_sessions))
            track_task(asyncio.create_task(cleanup_xhttp_session(evicted_id)))
        sess = {
            'id': session_id,
            'protocol': protocol,
            'r_reader': None,
            'r_writer': None,
            'downlink_queue': asyncio.Queue(maxsize=128),
            'uplink_queue': asyncio.Queue(maxsize=128),
            'next_uplink_seq': 0,
            'pending_uplink_map': {},
            'pending_uplink_bytes': 0,
            'unauth_buffered_bytes': 0,
            'is_parsed': False,
            'is_connected': False,
            'is_authenticated': False,
            'handshake_sent': False,
            'header_buf': bytearray(),
            'closed': False,
            'created_at': time.time(),
            'last_active': time.time(),
            'tasks': []
        }
        xhttp_sessions[session_id] = sess
    else:
        if sess.get('is_authenticated'):
            sess['last_active'] = time.time()
    return sess

async def xhttp_session_sweeper():
    while True:
        try:
            await asyncio.sleep(15)
            now = time.time()
            expired = []
            for sid, s in list(xhttp_sessions.items()):
                # 未认证的空头会话创建超过 15 秒强制销毁；已认证会话闲置超过 60 秒销毁
                if not s.get('is_authenticated'):
                    if now - s.get('created_at', now) > 15:
                        expired.append(sid)
                else:
                    if now - s.get('last_active', now) > 60:
                        expired.append(sid)
            for sid in expired:
                await cleanup_xhttp_session(sid)
        except asyncio.CancelledError:
            break
        except Exception:
            pass

async def cleanup_xhttp_session(session_id: str):
    sess = xhttp_sessions.pop(session_id, None)
    if not sess:
        return
    sess['closed'] = True
    global unauth_uplink_bytes_global
    if sess.get('unauth_buffered_bytes', 0) > 0:
        unauth_uplink_bytes_global = max(0, unauth_uplink_bytes_global - sess['unauth_buffered_bytes'])
        sess['unauth_buffered_bytes'] = 0
    if sess.get('r_writer'):
        try:
            sess['r_writer'].close()
            await sess['r_writer'].wait_closed()
        except Exception:
            pass
    try:
        sess['downlink_queue'].put_nowait(None)
    except Exception:
        pass
    for t in sess.get('tasks', []):
        if not t.done():
            t.cancel()

async def dispatch_xhttp_uplink(sess: dict, data: bytes):
    global unauth_uplink_bytes_global
    if sess['closed']:
        return
    if not sess['is_parsed']:
        sess['header_buf'].extend(data)
        if len(sess['header_buf']) > 2048:
            await cleanup_xhttp_session(sess['id'])
            return
        parsed = parse_vless_header(bytes(sess['header_buf'])) if sess['protocol'] == 'vless' else parse_trojan_header(bytes(sess['header_buf']))
        if parsed:
            sess['is_parsed'] = True
            sess['is_authenticated'] = True
            sess['last_active'] = time.time()
            if sess.get('unauth_buffered_bytes', 0) > 0:
                unauth_uplink_bytes_global = max(0, unauth_uplink_bytes_global - sess['unauth_buffered_bytes'])
                sess['unauth_buffered_bytes'] = 0
            r_reader, r_writer = await safe_open_connection(parsed['target_host'], parsed['target_port'])
            if not r_reader:
                await cleanup_xhttp_session(sess['id'])
                return
            if sess['closed'] or sess['id'] not in xhttp_sessions:
                try:
                    r_writer.close()
                    await r_writer.wait_closed()
                except Exception:
                    pass
                return
            sess['r_reader'] = r_reader
            sess['r_writer'] = r_writer
            sess['is_connected'] = True

            if sess['protocol'] == 'vless' and not sess['handshake_sent']:
                await sess['downlink_queue'].put(b'\x00\x00')
                sess['handshake_sent'] = True

            if parsed.get('payload'):
                r_writer.write(parsed['payload'])
                await r_writer.drain()

            while not sess['uplink_queue'].empty():
                q_item = await sess['uplink_queue'].get()
                r_writer.write(q_item)
                await r_writer.drain()

            async def remote_reader():
                try:
                    while not sess['closed']:
                        chunk = await r_reader.read(65536)
                        if not chunk:
                            break
                        await sess['downlink_queue'].put(chunk)
                except Exception:
                    pass
                finally:
                    await cleanup_xhttp_session(sess['id'])

            task = asyncio.create_task(remote_reader())
            sess['tasks'].append(task)
    else:
        if sess['is_connected'] and sess.get('r_writer'):
            try:
                sess['r_writer'].write(data)
                await sess['r_writer'].drain()
            except Exception:
                await cleanup_xhttp_session(sess['id'])
        else:
            await sess['uplink_queue'].put(data)

async def process_xhttp_uplink(sess: dict, data: bytes, seq: int = None):
    global unauth_uplink_bytes_global
    if sess['closed']:
        return
    if sess.get('is_authenticated'):
        sess['last_active'] = time.time()
    if seq is None:
        await dispatch_xhttp_uplink(sess, data)
        return

    # 严格按 seq 序号保序消费，防止 CDN/HTTP2 并发乱序损坏数据流
    if seq == sess['next_uplink_seq']:
        await dispatch_xhttp_uplink(sess, data)
        sess['next_uplink_seq'] += 1

        while sess['next_uplink_seq'] in sess['pending_uplink_map']:
            next_data = sess['pending_uplink_map'].pop(sess['next_uplink_seq'])
            data_len = len(next_data)
            sess['pending_uplink_bytes'] = max(0, sess.get('pending_uplink_bytes', 0) - data_len)
            if not sess.get('is_authenticated') and sess.get('unauth_buffered_bytes', 0) > 0:
                dec = min(sess['unauth_buffered_bytes'], data_len)
                sess['unauth_buffered_bytes'] -= dec
                unauth_uplink_bytes_global = max(0, unauth_uplink_bytes_global - dec)
            await dispatch_xhttp_uplink(sess, next_data)
            sess['next_uplink_seq'] += 1
    elif seq > sess['next_uplink_seq']:
        if seq in sess['pending_uplink_map']:
            return
        data_len = len(data)
        if not sess.get('is_authenticated'):
            # 未认证会话允许小额乱序缓冲（单会话 256KB，全局 16MB，15s 超时未认证自动释放）
            if (sess.get('unauth_buffered_bytes', 0) + data_len > UNAUTH_PER_SESSION_BYTES or
                unauth_uplink_bytes_global + data_len > UNAUTH_GLOBAL_BYTES):
                return
            sess['unauth_buffered_bytes'] = sess.get('unauth_buffered_bytes', 0) + data_len
            unauth_uplink_bytes_global += data_len
        else:
            # 已认证会话最多允许缓冲 4MB
            if sess.get('pending_uplink_bytes', 0) + data_len > 4 * 1024 * 1024:
                return

        sess['pending_uplink_map'][seq] = data
        sess['pending_uplink_bytes'] = sess.get('pending_uplink_bytes', 0) + data_len

@routes.get(f"{PATH_XHTTP}/{{session_id}}")
async def handle_vless_xhttp_get(request):
    if not ARGO_DOMAIN:
        return web.Response(status=404, text="Not Found")
    session_id = request.match_info['session_id']
    sess = get_or_create_xhttp_session(session_id, 'vless')
    if not sess:
        return web.Response(status=400, text="Bad Request")
    resp = web.StreamResponse(status=200, headers={
        'Content-Type': 'application/octet-stream',
        'Transfer-Encoding': 'chunked',
        'Cache-Control': 'no-cache, no-store, no-transform',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no'
    })
    await resp.prepare(request)
    try:
        while not sess['closed']:
            data = await sess['downlink_queue'].get()
            if data is None:
                break
            await resp.write(data)
    except Exception:
        pass
    finally:
        await cleanup_xhttp_session(session_id)
    return resp

@routes.post(f"{PATH_XHTTP}/{{session_id}}")
@routes.post(f"{PATH_XHTTP}/{{session_id}}/{{seq}}")
async def handle_vless_xhttp_post(request):
    if not ARGO_DOMAIN:
        return web.Response(status=404, text="Not Found")
    session_id = request.match_info['session_id']
    seq_str = request.match_info.get('seq')
    seq = int(seq_str) if seq_str and seq_str.isdigit() else None
    sess = get_or_create_xhttp_session(session_id, 'vless')
    if not sess:
        return web.Response(status=400, text="Bad Request")
    data = await request.read()
    if data:
        await process_xhttp_uplink(sess, data, seq)
    return web.Response(status=200, text="OK")

@routes.get(f"{PATH_TROJAN_XHTTP}/{{session_id}}")
async def handle_trojan_xhttp_get(request):
    if not ARGO_DOMAIN:
        return web.Response(status=404, text="Not Found")
    session_id = request.match_info['session_id']
    sess = get_or_create_xhttp_session(session_id, 'trojan')
    if not sess:
        return web.Response(status=400, text="Bad Request")
    resp = web.StreamResponse(status=200, headers={
        'Content-Type': 'application/octet-stream',
        'Transfer-Encoding': 'chunked',
        'Cache-Control': 'no-cache, no-store, no-transform',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no'
    })
    await resp.prepare(request)
    try:
        while not sess['closed']:
            data = await sess['downlink_queue'].get()
            if data is None:
                break
            await resp.write(data)
    except Exception:
        pass
    finally:
        await cleanup_xhttp_session(session_id)
    return resp

@routes.post(f"{PATH_TROJAN_XHTTP}/{{session_id}}")
@routes.post(f"{PATH_TROJAN_XHTTP}/{{session_id}}/{{seq}}")
async def handle_trojan_xhttp_post(request):
    if not ARGO_DOMAIN:
        return web.Response(status=404, text="Not Found")
    session_id = request.match_info['session_id']
    seq_str = request.match_info.get('seq')
    seq = int(seq_str) if seq_str and seq_str.isdigit() else None
    sess = get_or_create_xhttp_session(session_id, 'trojan')
    if not sess:
        return web.Response(status=400, text="Bad Request")
    data = await request.read()
    if data:
        await process_xhttp_uplink(sess, data, seq)
    return web.Response(status=200, text="OK")

@routes.post(PATH_XHTTP)
async def handle_xhttp(request):
    if not ARGO_DOMAIN:
        return web.Response(status=404, text="Not Found")
    # VLESS + xhttp (SplitHTTP) 原生全双工流（带 2KB 头部防探测保护）
    content = request.content
    first_chunk = await content.read(2048)
    parsed = parse_vless_header(first_chunk)
    if not parsed:
        return web.Response(status=400, text="Bad Request")

    r_reader, r_writer = await safe_open_connection(parsed['target_host'], parsed['target_port'])
    if not r_reader:
        return web.Response(status=403, text="Forbidden")

    resp = web.StreamResponse(status=200, headers={
        'Content-Type': 'application/octet-stream',
        'Transfer-Encoding': 'chunked',
        'Cache-Control': 'no-cache, no-store',
        'Connection': 'keep-alive'
    })
    await resp.prepare(request)
    await resp.write(b'\x00\x00') # VLESS 握手成功响应

    if parsed['payload']:
        r_writer.write(parsed['payload'])
        await r_writer.drain()

    async def pipe_req_to_remote():
        try:
            while True:
                chunk = await content.readany()
                if not chunk:
                    break
                r_writer.write(chunk)
                await r_writer.drain()
            if hasattr(r_writer, 'can_write_eof') and r_writer.can_write_eof():
                try:
                    r_writer.write_eof()
                except Exception:
                    pass
        except Exception:
            pass

    async def pipe_remote_to_resp():
        try:
            while True:
                data = await r_reader.read(65536)
                if not data:
                    break
                await resp.write(data)
        except Exception:
            pass

    t1 = asyncio.create_task(pipe_req_to_remote())
    t2 = asyncio.create_task(pipe_remote_to_resp())
    try:
        while not t2.done():
            if t1.done() and t1.exception():
                break
            done, _ = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
            if t2 in done:
                break
            if t1 in done:
                if t1.exception():
                    break
                await t2
                break
    finally:
        t1.cancel()
        t2.cancel()
        try:
            r_writer.close()
            await r_writer.wait_closed()
        except Exception:
            pass
    return resp

@routes.post(PATH_TROJAN_XHTTP)
async def handle_trojan_xhttp(request):
    if not ARGO_DOMAIN:
        return web.Response(status=404, text="Not Found")
    # Trojan + xhttp (SplitHTTP) 原生全双工流（带 2KB 头部防探测保护）
    content = request.content
    first_chunk = await content.read(2048)
    parsed = parse_trojan_header(first_chunk)
    if not parsed:
        return web.Response(status=400, text="Bad Request")

    r_reader, r_writer = await safe_open_connection(parsed['target_host'], parsed['target_port'])
    if not r_reader:
        return web.Response(status=403, text="Forbidden")

    resp = web.StreamResponse(status=200, headers={
        'Content-Type': 'application/octet-stream',
        'Transfer-Encoding': 'chunked',
        'Cache-Control': 'no-cache, no-store',
        'Connection': 'keep-alive'
    })
    await resp.prepare(request)

    if parsed['payload']:
        r_writer.write(parsed['payload'])
        await r_writer.drain()

    async def pipe_req_to_remote():
        try:
            while True:
                chunk = await content.readany()
                if not chunk:
                    break
                r_writer.write(chunk)
                await r_writer.drain()
            if hasattr(r_writer, 'can_write_eof') and r_writer.can_write_eof():
                try:
                    r_writer.write_eof()
                except Exception:
                    pass
        except Exception:
            pass

    async def pipe_remote_to_resp():
        try:
            while True:
                data = await r_reader.read(65536)
                if not data:
                    break
                await resp.write(data)
        except Exception:
            pass

    t1 = asyncio.create_task(pipe_req_to_remote())
    t2 = asyncio.create_task(pipe_remote_to_resp())
    try:
        while not t2.done():
            if t1.done() and t1.exception():
                break
            done, _ = await asyncio.wait([t1, t2], return_when=asyncio.FIRST_COMPLETED)
            if t2 in done:
                break
            if t1 in done:
                if t1.exception():
                    break
                await t2
                break
    finally:
        t1.cancel()
        t2.cancel()
        try:
            r_writer.close()
            await r_writer.wait_closed()
        except Exception:
            pass
    return resp

@routes.get(PATH_VLESS)
async def handle_vless_ws(request):
    ws = web.WebSocketResponse(max_msg_size=2 * 1024 * 1024)
    await ws.prepare(request)

    r_writer = None
    async def handshake_timeout():
        await asyncio.sleep(15)
        if not r_writer and not ws.closed:
            try:
                await ws.close(code=1008, message=b'Handshake timeout')
            except Exception:
                pass

    timeout_task = asyncio.create_task(handshake_timeout())
    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                data = msg.data
                if not r_writer:
                    timeout_task.cancel()
                    parsed = parse_vless_header(data)
                    if not parsed:
                        await ws.close()
                        break
                    r_reader, r_writer = await safe_open_connection(parsed['target_host'], parsed['target_port'])
                    if not r_reader:
                        await ws.close()
                        break
                    await ws.send_bytes(b'\x00\x00')
                    if parsed['payload']:
                        r_writer.write(parsed['payload'])
                        await r_writer.drain()

                    async def pipe_remote_to_ws():
                        try:
                            while not ws.closed:
                                r_data = await r_reader.read(65536)
                                if not r_data:
                                    break
                                await ws.send_bytes(r_data)
                        except Exception:
                            pass
                        finally:
                            await ws.close()

                    track_task(asyncio.create_task(pipe_remote_to_ws()))
                else:
                    r_writer.write(data)
                    await r_writer.drain()
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break
    finally:
        timeout_task.cancel()
        if r_writer:
            try:
                r_writer.close()
                await r_writer.wait_closed()
            except Exception:
                pass
    return ws

@routes.get(PATH_TROJAN)
async def handle_trojan_ws(request):
    ws = web.WebSocketResponse(max_msg_size=2 * 1024 * 1024)
    await ws.prepare(request)

    r_writer = None
    async def handshake_timeout():
        await asyncio.sleep(15)
        if not r_writer and not ws.closed:
            try:
                await ws.close(code=1008, message=b'Handshake timeout')
            except Exception:
                pass

    timeout_task = asyncio.create_task(handshake_timeout())
    try:
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                data = msg.data
                if not r_writer:
                    timeout_task.cancel()
                    parsed = parse_trojan_header(data)
                    if not parsed:
                        await ws.close()
                        break
                    r_reader, r_writer = await safe_open_connection(parsed['target_host'], parsed['target_port'])
                    if not r_reader:
                        await ws.close()
                        break
                    if parsed['payload']:
                        r_writer.write(parsed['payload'])
                        await r_writer.drain()

                    async def pipe_remote_to_ws():
                        try:
                            while not ws.closed:
                                r_data = await r_reader.read(65536)
                                if not r_data:
                                    break
                                await ws.send_bytes(r_data)
                        except Exception:
                            pass
                        finally:
                            await ws.close()

                    track_task(asyncio.create_task(pipe_remote_to_ws()))
                else:
                    r_writer.write(data)
                    await r_writer.drain()
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                break
    finally:
        timeout_task.cancel()
        if r_writer:
            try:
                r_writer.close()
                await r_writer.wait_closed()
            except Exception:
                pass
    return ws

# ── 启动与退出控制 ─────────────────────────────────────────────────────────
is_dual_stack = not LISTEN_HOST or LISTEN_HOST in ('0.0.0.0', '::')
is_loopback = LISTEN_HOST in ('127.0.0.1', 'localhost')

async def on_startup(app):
    loop = asyncio.get_running_loop()
    loop.set_exception_handler(handle_global_exception)

    global node_name_task
    node_name_task = asyncio.create_task(resolve_node_name())
    if is_dual_stack:
        listen_addr = f"0.0.0.0 / [::]:{PORT} (全接口双栈)"
    elif is_loopback:
        listen_addr = f"127.0.0.1 + [::1]:{PORT} (本地双栈回环，防公网暴露)"
    else:
        listen_addr = f"{HOST}:{PORT}"
    print("====================================================")
    print("🚀 Argo (Zero-Binary 纯原生穿透引擎 - Python版) 已启动")
    print(f"📡 内部监听: {listen_addr}")
    if NODE_NAME:
        print(f"🏷️  节点标识: {NODE_NAME}")
    print(f"🔑 核心 UUID: {UUID}")
    print(f"🔒 独立密码: {PASSWORD}")
    print("====================================================")

    track_task(asyncio.create_task(xhttp_session_sweeper()))
    track_task(asyncio.create_task(start_argo_tunnel(PORT)))
    track_task(asyncio.create_task(start_komari()))

async def on_cleanup(app):
    global is_shutting_down
    is_shutting_down = True
    print("\n[安全退出] 正在清理子进程并释放资源...")
    for sid in list(xhttp_sessions.keys()):
        try:
            await cleanup_xhttp_session(sid)
        except Exception:
            pass
    for proc in list(tracked_processes):
        try:
            proc.terminate()
        except Exception:
            pass
    kill_stale_by_tag()
    if platform.system().lower() == 'linux':
        try:
            subprocess.run(['umount', '/proc/uptime'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
        try:
            Path('/tmp/.fake_uptime').unlink(missing_ok=True)
        except Exception:
            pass

def main():
    kill_stale_by_tag()
    app = web.Application(client_max_size=2 * 1024 * 1024)
    app.add_routes(routes)
    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)

    if is_loopback:
        async def run_dual_loopback():
            runner = web.AppRunner(app)
            await runner.setup()
            site_v4 = web.TCPSite(runner, '127.0.0.1', PORT)
            await site_v4.start()
            try:
                site_v6 = web.TCPSite(runner, '::1', PORT)
                await site_v6.start()
            except Exception:
                pass

            stop_event = asyncio.Event()
            loop = asyncio.get_running_loop()
            for sig in (signal.SIGINT, signal.SIGTERM):
                try:
                    loop.add_signal_handler(sig, stop_event.set)
                except (NotImplementedError, AttributeError):
                    pass
            try:
                await stop_event.wait()
            except (asyncio.CancelledError, KeyboardInterrupt):
                pass
            finally:
                await runner.cleanup()

        try:
            asyncio.run(run_dual_loopback())
        except (KeyboardInterrupt, SystemExit):
            pass
    else:
        run_host = None if is_dual_stack else LISTEN_HOST
        web.run_app(app, host=run_host, port=PORT)

if __name__ == '__main__':
    main()
