# Argo

> **Zero-Binary (零外部内核) 纯原生穿透代理系统**  
> 彻底摆脱对 `sing-box` / `Xray` 等外部可执行二进制内核的依赖，100% 由原生代码实现协议握手与数据转发。基于 Cloudflare Argo 隧道，实现 0 入站端口暴露、免申请 TLS 证书、防封锁救砖，专为现代免费 PaaS 容器平台（Koyeb、Render、HuggingFace、Railway 等）与轻量 VPS 量身定制。

---

## 🌟 核心特色

1. **Zero-Binary 纯原生代理引擎（Node.js & Python 双版本）**
   - **零二进制外挂**：没有下载和运行 `sing-box`、`xray` 等非系统级二进制文件，系统进程仅有原生的 `node` 或 `python`，彻底免疫平台对可执行代理二进制的扫描查杀。
   - **秒级冷启动**：开机无需等待外部庞大内核下载解压，毫秒级瞬时就绪，彻底告别 GitHub API 限流（HTTP 403）和 libc 兼容问题。
   - **极低内存占用**：Node.js 版运行时仅需 **~30MB** 内存，高并发 I/O 吞吐极佳，即使在 256MB/512MB 内存的极小容器中也能稳定常驻。

2. **100% Argo 隧道集成（0 端口暴露）**
   - 无需公网入站端口，无需繁琐的 ACME 证书申请与续期。
   - 支持 **临时穿透隧道**（开箱即用，动态解析）与 **固定 Token 隧道**（稳定域名）。
   - 固定隧道 Token 采用系统环境变量传递，不在 CLI 命令行暴露，避免 `ps aux` 敏感凭证泄露。

3. **3 大原生高能协议矩阵**
   - `VLESS + xhttp + Argo TLS`（最新 SplitHTTP 流式全双工传输，带 2KB 头部防探测保护）
   - `VLESS + WS + Argo TLS`（经典通用高兼容 WebSocket）
   - `Trojan + WS + Argo TLS`（高隐蔽 Trojan 流量）

4. **双向保活守护与反查杀**
   - 内置守护保活引擎，支持指数退避重启（3s ~ 60s），被平台意外杀死后自动拉起。
   - Node.js 版内置进程名伪装（`node /app/bridge.js`）。

5. **全自动订阅与多通道分发**
   - 自动探测公网出口并标准化生成 `国家-运营商` 节点名称（如 `HK-Tencent`）。
   - **多通道分发**：支持 `/sub` HTTP 订阅路径、控制台 Base64 输出、Telegram 实时推送。
   - **隐私保护与自洁**：控制台初始日志与临时 `sub.txt` 配置文件定时自动清理自毁（默认 2 分钟），转入静默守护模式。

6. **Komari 监控探针无缝集成**
   - 原生支持 Komari 探针，集成容器在线时长虚拟化（解决容器平台宿主机运行几百天导致的探针统计异常问题）。

---

## 📂 工程结构

```text
argo/
├── nodejs/               # Node.js 纯原生端（极速轻量首选，内存仅 ~30MB）
│   ├── index.js          # 原生协议引擎、隧道守护与订阅中心
│   ├── index.html        # 高质量静态伪装页面（灯塔守望者日记）
│   └── package.json
├── python/               # Python 异步全双工纯原生端（asyncio + aiohttp）
│   ├── app.py
│   ├── index.html
│   └── requirements.txt
├── Dockerfile            # 官方推荐 Node.js 极速轻量镜像构建文件
├── .dockerignore
└── README.md
```

---

## ⚙️ 环境变量配置

所有配置项均支持通过**环境变量**注入（留空则自动使用安全预设值）：

| 环境变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `UUID` | `a982ac5f-9acd-4d38-9140-56f0b27c6961` | 核心连接 UUID（VLESS 鉴权） |
| `PASSWORD` | 复用 `UUID` | Trojan 密码（留空默认直接复用 UUID） |
| `PORT` | `3000` | 内部 HTTP 监听端口 |
| `SUB` | `sub` | 订阅路径后缀（即访问 `https://域名/sub`） |
| `NAME` | 自动识别 | 自定义节点标识（留空自动识别并格式化为 `国家-运营商`，如 `US-Cloudflare`） |
| `ARGO_DOMAIN` | 留空 | 固定隧道域名（如 `myargo.example.com`，留空则自动申请临时隧道） |
| `ARGO_AUTH` | 留空 | 固定隧道 Token 凭证（留空使用临时隧道） |
| `ARGO_PROTOCOL` | 留空 | Argo 连接协议（留空由 cloudflared 自动选择，可选 `http2`、`quic`） |
| `CF_PREFER_HOST`| `www.visa.com.tw` | 节点连接中的 Cloudflare 优选域名或优选 IP |
| `KOMARI_DOMAIN` | 留空 | Komari 服务端域名/地址（留空不启用探针） |
| `KOMARI_TOKEN`  | 留空 | Komari 探针密钥 Token |
| `SHOW_LOG`      | `true` | 是否在控制台打印订阅内容（`true` / `false`） |
| `LOG_CLEAR_MINUTES` | `2` | 控制台配置打印后自动清屏及清理 `sub.txt` 的时间（分钟，`0` 为不清理） |
| `TG_BOT_TOKEN`  | 留空 | Telegram Bot Token（用于自动推送订阅信息） |
| `TG_CHAT_ID`    | 留空 | Telegram Chat ID |

---

## 🚀 部署指南

### 方式一：Docker 运行（推荐）

#### 1. 临时隧道模式（无需任何域名和 Token，开箱即用）
```bash
docker run -d \
  --name argo \
  --restart unless-stopped \
  -e UUID="a982ac5f-9acd-4d38-9140-56f0b27c6961" \
  ghcr.io/zaofengyue/argo:latest
```
> 容器启动后，查看日志即可获取生成的 `trycloudflare.com` 穿透域名和 Base64 订阅：
> ```bash
> docker logs argo
> ```

#### 2. 固定隧道模式（绑定自己的 Cloudflare 域名）
```bash
docker run -d \
  --name argo \
  --restart unless-stopped \
  -e ARGO_DOMAIN="your-tunnel-domain.com" \
  -e ARGO_AUTH="eyJhIjoi..." \
  -e TG_BOT_TOKEN="123456:ABC-DEF..." \
  -e TG_CHAT_ID="12345678" \
  ghcr.io/zaofengyue/argo:latest
```

---

### 方式二：Docker Compose 编排

创建 `docker-compose.yml`：

```yaml
version: '3.8'

services:
  argo:
    image: ghcr.io/zaofengyue/argo:latest
    container_name: argo
    restart: unless-stopped
    environment:
      - UUID=a982ac5f-9acd-4d38-9140-56f0b27c6961
      # 如使用固定隧道请填入以下两项：
      # - ARGO_DOMAIN=your-tunnel.example.com
      # - ARGO_AUTH=eyJhIjoi...
      # Telegram 自动推送（可选）：
      # - TG_BOT_TOKEN=
      # - TG_CHAT_ID=
      # 优选域名/IP（可选）：
      # - CF_PREFER_HOST=www.visa.com.tw
```

启动命令：
```bash
docker compose up -d
```

---

### 方式三：云端免费 PaaS 容器平台部署（Koyeb、Render、HuggingFace 等）

1. **仓库构建**：将本项目推送到您的 GitHub 私有或公开仓库。
2. **选择构建方式**：直接选择 **Dockerfile** 构建。
3. **设置环境变量**：在平台的 Environment Variables 界面填入你需要的变量（如 `UUID`、`ARGO_AUTH`、`ARGO_DOMAIN`、`TG_BOT_TOKEN` 等）。
4. **部署上线**：平台拉取代码完成构建后自动启动，无需映射公网端口（全部流量经由 Cloudflare Argo 安全传输）。

---

### 方式四：本地 / VPS 直接运行

#### 运行 Node.js 版
```bash
cd nodejs
npm install
node index.js
```

#### 运行 Python 版
```bash
cd python
pip install -r requirements.txt
python app.py
```

---

## 📱 客户端导入与使用

服务启动后，可以通过以下途径导入节点：

1. **直接订阅导入**：在 v2rayN、Shadowrocket、Clash Verge 等客户端中添加订阅链接：
   ```text
   https://<你的穿透域名>/sub
   ```
2. **批量复制导入**：复制控制台输出或 Telegram 推送中的 Base64 编码，在客户端中选择“从剪贴板导入”。
3. **支持客户端**：Sing-box、v2rayN、v2rayNG、Shadowrocket、NekoBox、Clash Verge rev 等主流客户端。
