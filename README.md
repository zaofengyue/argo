# Argo

> **Zero-Binary (零外部内核) 纯原生穿透代理系统**  
---

## 🚀 部署指南

### 方式一：Linux VPS 一键管理脚本

适用于任意 Ubuntu / Debian / CentOS 等 Linux VPS 服务器，全自动配置环境与守护进程：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zaofengyue/argo/main/argo.sh)
```

- **全中文交互面板**：支持一键安装、修改 UUID / 密码 / 端口 / Argo 穿透模式（临时或固定）、配置 TG 推送与探针；
- **后台守护保活**：自动注册 `systemd` 服务，开机自启，故障自动拉起；
- **系统快捷指令**：安装后在 VPS 终端随时输入 `argo`（或短别名 `ag`）即可使用以下快捷命令：

| 快捷命令 | 功能说明 |
| :--- | :--- |
| `argo` 或 `ag` | 打开全中文交互式管理面板（默认） |
| `argo start` | 启动 Argo 代理服务 |
| `argo stop` | 停止 Argo 代理服务 |
| `argo restart` | 重启 Argo 代理服务 |
| `argo status` | 查看运行状态、主进程 PID 与内存占用 |
| `argo sub` | 查看节点连接链接与 Base64 订阅内容 |
| `argo log` | 实时查看运行日志（`Ctrl+C` 退出） |
| `argo edit` | 修改核心配置参数（UUID/密码/端口/隧道Token/TG推送） |
| `argo update` | 一键检查并拉取最新服务端代码并平滑重启 |
| `argo uninstall`| 彻底卸载 Argo 服务与所有配置文件 |
| `argo help` | 打印常用命令行帮助目录 |

---

### 方式二：Docker 运行

支持 GitHub Container Registry (`ghcr.io/zaofengyue/argo:latest`) 与 Docker Hub (`zaofengyue/argo:latest`) 双镜像源：

#### 1. 临时隧道模式
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

#### 2. 固定隧道模式
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

### 方式三：Docker Compose 编排

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

### 方式四：云端免费 PaaS 容器平台部署

1. **仓库构建**：将本项目推送到您的 GitHub 私有或公开仓库。
2. **选择构建方式**：直接选择 **Dockerfile** 构建。
3. **设置环境变量**：在平台的 Environment Variables 界面填入你需要的变量（如 `UUID`、`ARGO_AUTH`、`ARGO_DOMAIN`、`TG_BOT_TOKEN` 等）。
4. **部署上线**：平台拉取代码完成构建后自动启动，无需映射公网端口（全部流量经由 Cloudflare Argo 安全传输）。

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
