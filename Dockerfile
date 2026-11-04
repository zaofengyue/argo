FROM node:20-alpine

ARG TARGETARCH

WORKDIR /app

# 1. 安装基础工具与兼容运行库（保证 Alpine 下 Go 静态/动态二进制兼容及 PID 1 信号管理）
RUN apk add --no-cache curl bash ca-certificates procps gcompat libc6-compat tini

# 2. 预置多架构穿透与监控工具（秒级冷启动，避免运行时临时下载失败）
RUN set -eux; \
    mkdir -p /root/.argo-core /root/.cache/node-core /usr/local/bin; \
    case "${TARGETARCH}" in \
      amd64) \
        CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
      arm64) \
        CF_ARCH="linux-arm64"; KM_ARCH="linux-arm64" ;; \
      *) \
        CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
    esac; \
    # 下载 cloudflared 穿透核心并放置到核心目录
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" -o /root/.argo-core/bridge; \
    chmod +x /root/.argo-core/bridge; \
    # 下载 komari-agent 探针并放置到核心目录
    curl -fsSL "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-${KM_ARCH}" -o /root/.argo-core/metrics; \
    chmod +x /root/.argo-core/metrics; \
    # 软链接兼容
    ln -sf /root/.argo-core/bridge /usr/local/bin/cloudflared; \
    ln -sf /root/.argo-core/metrics /usr/local/bin/komari-agent

# 3. 安装依赖与复制代码
COPY nodejs/package.json ./
RUN npm install --omit=dev

COPY nodejs/ ./

ENV HOST=0.0.0.0
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fs http://127.0.0.1:3000/ || exit 1

ENTRYPOINT ["/sbin/tini", "--"]

CMD ["node", "index.js"]
