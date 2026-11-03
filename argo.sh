#!/usr/bin/env bash
# ==============================================================================
# Argo - Zero-Binary 纯原生代理服务端一键管理脚本
# GitHub: https://github.com/zaofengyue/argo
# ==============================================================================

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# ── 颜色定义 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── 路径与常量 ────────────────────────────────────────────────────────────────
APP_DIR="/opt/argo"
ENV_FILE="$APP_DIR/config.env"
SVC_NAME="argo"
SVC_FILE="/etc/systemd/system/${SVC_NAME}.service"
BIN_LINK="/usr/local/bin/argo"
REPO_RAW="https://raw.githubusercontent.com/zaofengyue/argo/main"

# ── 日志工具 ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 权限与系统检查 ────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 root 权限运行，请使用 sudo -i 或切换为 root 用户后执行！"
        exit 1
    fi
}

check_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "当前系统不支持 systemd，本脚本仅支持带 systemd 的 Linux 发行版 (Debian / Ubuntu / CentOS / AlmaLinux / Rocky 等)！"
        exit 1
    fi
}

# ── 包管理器探测与依赖安装 ───────────────────────────────────────────────────
install_dependencies() {
    log_info "正在检测并安装基础依赖 (curl, tar, git, ca-certificates)..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl tar git ca-certificates openssl procps
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl tar git ca-certificates openssl procps-ng
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl tar git ca-certificates openssl procps-ng
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl tar git ca-certificates openssl procps-ng
    fi
}

# ── Node.js 运行时探测与自动安装 ─────────────────────────────────────────────
ensure_nodejs() {
    local need_install=0
    if command -v node >/dev/null 2>&1; then
        local ver
        ver=$(node -v | sed 's/v//' | cut -d. -f1)
        if [[ "$ver" -ge 18 ]]; then
            log_info "检测到可用的 Node.js 运行环境: $(node -v)"
            return 0
        else
            log_warn "当前 Node.js 版本过低 ($(node -v))，需要 Node.js 18+，正在自动升级..."
            need_install=1
        fi
    else
        need_install=1
    fi

    if [[ "$need_install" -eq 1 ]]; then
        log_info "正在自动安装 Node.js LTS 官方运行库..."
        if command -v apt-get >/dev/null 2>&1; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt-get install -y nodejs
        elif command -v dnf >/dev/null 2>&1; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            dnf install -y nodejs
        elif command -v yum >/dev/null 2>&1; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            yum install -y nodejs
        fi

        if ! command -v node >/dev/null 2>&1; then
            log_error "Node.js 自动安装失败，请手动安装 Node.js 20 后重新运行脚本！"
            exit 1
        fi
        log_info "Node.js 安装成功: $(node -v)"
    fi
}

# ── 配置读写工具 ──────────────────────────────────────────────────────────────
get_env() {
    local key="$1"
    if [[ -f "$ENV_FILE" ]]; then
        grep "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'"
    fi
}

set_env() {
    local key="$1" val="$2"
    mkdir -p "$APP_DIR"
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_FILE"
    else
        echo "${key}=\"${val}\"" >> "$ENV_FILE"
    fi
}

# ── 交互式配置输入 ────────────────────────────────────────────────────────────
configure_service() {
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${WHITE}           🚀 Argo 服务端配置向导${NC}"
    echo -e "${CYAN}====================================================${NC}\n"

    # 1. 核心 UUID
    local def_uuid
    def_uuid=$(get_env "UUID")
    if [[ -z "$def_uuid" ]]; then
        if command -v uuidgen >/dev/null 2>&1; then
            def_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        else
            def_uuid="a982ac5f-9acd-4d38-9140-56f0b27c6961"
        fi
    fi
    echo -e "${WHITE}1. 请设置核心 UUID${NC} (回车默认使用: ${GREEN}${def_uuid}${NC})"
    read -rp "   请输入 UUID: " input_uuid
    local final_uuid="${input_uuid:-$def_uuid}"
    set_env "UUID" "$final_uuid"

    # 2. 独立密码
    local def_pwd
    def_pwd=$(get_env "PASSWORD")
    [[ -z "$def_pwd" ]] && def_pwd="$final_uuid"
    echo -e "\n${WHITE}2. 请设置 Trojan 密码${NC} (回车默认复用 UUID: ${GREEN}${final_uuid}${NC})"
    read -rp "   请输入密码: " input_pwd
    set_env "PASSWORD" "${input_pwd:-$def_pwd}"

    # 3. 内部端口
    local def_port
    def_port=$(get_env "PORT")
    [[ -z "$def_port" ]] && def_port="3000"
    echo -e "\n${WHITE}3. 请设置本地 HTTP 监听端口${NC} (回车默认: ${GREEN}${def_port}${NC})"
    read -rp "   请输入端口: " input_port
    set_env "PORT" "${input_port:-$def_port}"

    # 4. 节点名称
    local def_name
    def_name=$(get_env "NAME")
    echo -e "\n${WHITE}4. 请设置节点自定义标识名称${NC} (回车默认: ${GREEN}自动探测 国家-运营商${NC})"
    read -rp "   请输入节点名称 (留空自动探测): " input_name
    set_env "NAME" "${input_name:-$def_name}"

    # 5. Argo 隧道模式
    echo -e "\n${WHITE}5. 请选择 Cloudflare Argo 穿透模式:${NC}"
    echo -e "   ${GREEN}1.${NC} 临时隧道 (无需域名和凭证，开箱即用，由 Cloudflare 自动分配 trycloudflare.com 域名)"
    echo -e "   ${GREEN}2.${NC} 固定隧道 (需绑定自己的 Cloudflare 域名与 Tunnel Token)"
    read -rp "   请输入选项 [1-2] (默认 1): " argo_choice

    if [[ "$argo_choice" == "2" ]]; then
        local def_domain def_auth
        def_domain=$(get_env "ARGO_DOMAIN")
        def_auth=$(get_env "ARGO_AUTH")

        read -rp "   请输入已绑定的固定隧道域名 (如 tunnel.example.com): " input_domain
        read -rp "   请输入 Cloudflare Tunnel Token: " input_auth

        set_env "ARGO_DOMAIN" "${input_domain:-$def_domain}"
        set_env "ARGO_AUTH" "${input_auth:-$def_auth}"
    else
        set_env "ARGO_DOMAIN" ""
        set_env "ARGO_AUTH" ""
    fi

    # 6. CF 优选域名
    local def_cf
    def_cf=$(get_env "CF_PREFER_HOST")
    [[ -z "$def_cf" ]] && def_cf="www.visa.com.tw"
    echo -e "\n${WHITE}6. 请设置 Cloudflare 优选域名/IP${NC} (回车默认: ${GREEN}${def_cf}${NC})"
    read -rp "   请输入优选域名: " input_cf
    set_env "CF_PREFER_HOST" "${input_cf:-$def_cf}"

    # 7. Telegram 推送 (可选)
    local def_tg_token def_tg_chat
    def_tg_token=$(get_env "TG_BOT_TOKEN")
    def_tg_chat=$(get_env "TG_CHAT_ID")
    echo -e "\n${WHITE}7. 是否启用 Telegram Bot 自动推送订阅? (可选)${NC}"
    read -rp "   请输入 TG_BOT_TOKEN (回车跳过): " input_tg_token
    if [[ -n "$input_tg_token" ]]; then
        read -rp "   请输入 TG_CHAT_ID: " input_tg_chat
        set_env "TG_BOT_TOKEN" "$input_tg_token"
        set_env "TG_CHAT_ID" "$input_tg_chat"
    fi

    # 8. Komari 探针 (可选)
    local def_km_domain def_km_token
    def_km_domain=$(get_env "KOMARI_DOMAIN")
    def_km_token=$(get_env "KOMARI_TOKEN")
    echo -e "\n${WHITE}8. 是否启用 Komari 监控探针? (可选)${NC}"
    read -rp "   请输入 Komari 服务端域名 (回车跳过): " input_km_domain
    if [[ -n "$input_km_domain" ]]; then
        read -rp "   请输入 Komari 探针 Token: " input_km_token
        set_env "KOMARI_DOMAIN" "$input_km_domain"
        set_env "KOMARI_TOKEN" "$input_km_token"
    fi

    log_info "配置参数已成功保存至: ${ENV_FILE}"
}

# ── 安装 / 更新核心代码 ───────────────────────────────────────────────────────
deploy_core() {
    log_info "正在配置 Argo 核心目录: ${APP_DIR}..."
    mkdir -p "$APP_DIR/nodejs"

    log_info "正在获取最新 Argo 服务端代码..."
    curl -fsSL "${REPO_RAW}/nodejs/index.js" -o "$APP_DIR/nodejs/index.js"
    curl -fsSL "${REPO_RAW}/nodejs/package.json" -o "$APP_DIR/nodejs/package.json"
    curl -fsSL "${REPO_RAW}/nodejs/index.html" -o "$APP_DIR/nodejs/index.html"

    log_info "正在安装 Node.js 依赖..."
    cd "$APP_DIR/nodejs" || exit 1
    npm install --omit=dev --silent

    # 复制本脚本为全局管理快捷命令 (支持 argo 与短命令 ag)
    cp -f "$0" "$APP_DIR/argo.sh" 2>/dev/null || true
    chmod +x "$APP_DIR/argo.sh"
    ln -sf "$APP_DIR/argo.sh" "$BIN_LINK"
    chmod +x "$BIN_LINK"
    ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
}

# ── 注册 Systemd 守护服务 ─────────────────────────────────────────────────────
install_service() {
    log_info "正在注册 systemd 系统守护服务 (${SVC_NAME})..."
    local node_bin
    node_bin=$(command -v node)

    cat > "$SVC_FILE" <<EOF
[Unit]
Description=Argo Zero-Binary Proxy Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}/nodejs
EnvironmentFile=-${ENV_FILE}
ExecStart=${node_bin} index.js
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >/dev/null 2>&1
    systemctl restart "$SVC_NAME"
    log_info "Argo 服务已启动并设置开机自启！"
}

# ── 运行状态查询 ──────────────────────────────────────────────────────────────
check_status() {
    if systemctl is-active --quiet "$SVC_NAME"; then
        echo -e "Argo 运行状态: ${GREEN}● 正在运行 (Active)${NC}"
        local pid
        pid=$(pgrep -f "node index.js" | head -1)
        if [[ -n "$pid" ]]; then
            local mem
            mem=$(ps -p "$pid" -o rss= 2>/dev/null | awk '{print int($1/1024)"MB"}')
            echo -e "主进程 PID:   ${CYAN}${pid}${NC}"
            echo -e "内存占用:     ${CYAN}${mem:-未知}${NC}"
        fi
    else
        echo -e "Argo 运行状态: ${RED}○ 未运行 (Stopped)${NC}"
    fi
}

# ── 节点与订阅展示 ────────────────────────────────────────────────────────────
show_subscription() {
    echo -e "\n${CYAN}================= 🚀 Argo 节点订阅与配置 ================${NC}"
    local sub_file="$APP_DIR/nodejs/sub.txt"
    if [[ ! -f "$sub_file" ]]; then
        sub_file="$(pwd)/sub.txt"
    fi

    if [[ -f "$sub_file" ]]; then
        echo -e "${YELLOW}Base64 订阅内容:${NC}"
        cat "$sub_file"
        echo -e "\n${CYAN}========================================================${NC}\n"
    fi

    # 从日志中提取最新域名与信息
    local domain
    domain=$(journalctl -u "$SVC_NAME" --no-pager -n 50 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1)
    if [[ -z "$domain" ]]; then
        domain=$(get_env "ARGO_DOMAIN")
        [[ -n "$domain" ]] && domain="https://${domain}"
    fi

    if [[ -n "$domain" ]]; then
        local sub_path
        sub_path=$(get_env "SUB")
        [[ -z "$sub_path" ]] && sub_path="sub"
        echo -e "穿透地址: ${WHITE}${domain}${NC}"
        echo -e "订阅链接: ${GREEN}${domain}/${sub_path}${NC}"
    else
        echo -e "${YELLOW}服务启动中，请稍后查看日志或稍后再次选择本项查询域名。${NC}"
    fi
    echo -e "${CYAN}========================================================${NC}\n"
}

# ── 卸载清理 ──────────────────────────────────────────────────────────────────
uninstall_argo() {
    echo -e "${RED}确定要彻底卸载 Argo 服务吗? 相关的配置和数据都将被删除！${NC}"
    read -rp "请输入 'y' 确认卸载: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_info "已取消卸载。"
        return 0
    fi

    log_info "正在停止并清理 Argo 服务..."
    systemctl stop "$SVC_NAME" >/dev/null 2>&1
    systemctl disable "$SVC_NAME" >/dev/null 2>&1
    rm -f "$SVC_FILE"
    systemctl daemon-reload

    pkill -f "bridge" 2>/dev/null || true
    pkill -f "metrics" 2>/dev/null || true
    pkill -f "node /app/bridge.js" 2>/dev/null || true
    pkill -f "node index.js" 2>/dev/null || true

    rm -rf "$APP_DIR"
    rm -f "$BIN_LINK"
    rm -f "/usr/local/bin/ag" 2>/dev/null || true
    rm -rf "$HOME/.argo-core"

    log_info "Argo 服务及所有配置文件已彻底清除！"
}

# ── 主菜单交互 ────────────────────────────────────────────────────────────────
main_menu() {
    clear
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${WHITE}      Argo - Zero-Binary 纯原生代理服务端管理面板${NC}"
    echo -e "${CYAN}====================================================${NC}"
    check_status
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " ${GREEN}1.${NC} 安装 / 重装 Argo 服务"
    echo -e " ${GREEN}2.${NC} 启动服务"
    echo -e " ${GREEN}3.${NC} 停止服务"
    echo -e " ${GREEN}4.${NC} 重启服务"
    echo -e " ${GREEN}5.${NC} 查看节点订阅信息"
    echo -e " ${GREEN}6.${NC} 实时查看运行日志"
    echo -e " ${GREEN}7.${NC} 修改核心配置参数"
    echo -e " ${GREEN}8.${NC} 更新脚本与服务端核心"
    echo -e " ${RED}9.${NC} 彻底卸载 Argo"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " ${WHITE}0.${NC} 退出脚本"
    echo -e "${CYAN}====================================================${NC}"
    read -rp "请输入数字 [0-9]: " choice

    case "$choice" in
        1)
            check_root
            check_systemd
            install_dependencies
            ensure_nodejs
            configure_service
            deploy_core
            install_service
            sleep 3
            show_subscription
            ;;
        2)
            check_root
            systemctl start "$SVC_NAME"
            log_info "服务已启动。"
            ;;
        3)
            check_root
            systemctl stop "$SVC_NAME"
            log_info "服务已停止。"
            ;;
        4)
            check_root
            systemctl restart "$SVC_NAME"
            log_info "服务已重启。"
            ;;
        5)
            show_subscription
            ;;
        6)
            echo -e "${YELLOW}按 Ctrl+C 退出实时日志查看...${NC}\n"
            journalctl -u "$SVC_NAME" -f -n 50
            ;;
        7)
            check_root
            configure_service
            systemctl restart "$SVC_NAME"
            log_info "配置已重新载入并重启生效！"
            ;;
        8)
            check_root
            log_info "正在拉取最新代码更新..."
            deploy_core
            systemctl restart "$SVC_NAME"
            log_info "Argo 已更新至最新版本并重启！"
            ;;
        9)
            check_root
            uninstall_argo
            ;;
        0)
            exit 0
            ;;
        *)
            log_error "无效选项，请输入 0-9 之间的数字！"
            ;;
    esac
}

# ── 命令行帮助目录 ────────────────────────────────────────────────────────────
show_help() {
    echo -e "${CYAN}====================================================${NC}"
    echo -e "${WHITE}      Argo - Zero-Binary 命令行常用指令目录${NC}"
    echo -e "${CYAN}====================================================${NC}"
    echo -e " ${GREEN}argo${NC} (或 ${GREEN}ag${NC})          - 呼出交互式管理主菜单 (默认)"
    echo -e " ${GREEN}argo start${NC}         - 启动 Argo 代理服务"
    echo -e " ${GREEN}argo stop${NC}          - 停止 Argo 代理服务"
    echo -e " ${GREEN}argo restart${NC}       - 重启 Argo 代理服务"
    echo -e " ${GREEN}argo status${NC}        - 查看服务运行状态、PID 与内存占用"
    echo -e " ${GREEN}argo sub${NC}           - 查看节点连接链接与 Base64 订阅内容"
    echo -e " ${GREEN}argo log${NC}           - 实时查看服务运行日志 (按 Ctrl+C 退出)"
    echo -e " ${GREEN}argo edit${NC}          - 修改核心参数 (UUID/密码/端口/隧道Token/TG推送)"
    echo -e " ${GREEN}argo update${NC}        - 一键检查并拉取更新服务端到最新版"
    echo -e " ${RED}argo uninstall${NC}     - 彻底卸载 Argo 服务与所有配置文件"
    echo -e " ${GREEN}argo help${NC}          - 显示本命令行帮助目录"
    echo -e "${CYAN}====================================================${NC}"
}

# ── 脚本入口 ──────────────────────────────────────────────────────────────────
check_root

if [[ -n "$1" ]]; then
    case "$1" in
        install)
            check_systemd
            install_dependencies
            ensure_nodejs
            configure_service
            deploy_core
            install_service
            sleep 3
            show_subscription
            ;;
        menu)    main_menu ;;
        start)   systemctl start "$SVC_NAME"; log_info "服务已启动。" ;;
        stop)    systemctl stop "$SVC_NAME"; log_info "服务已停止。" ;;
        restart) systemctl restart "$SVC_NAME"; log_info "服务已重启。" ;;
        status)  check_status ;;
        sub)     show_subscription ;;
        log)     journalctl -u "$SVC_NAME" -f -n 50 ;;
        edit|config)
            configure_service
            systemctl restart "$SVC_NAME"
            log_info "配置已重新载入并重启生效！"
            ;;
        update|upgrade)
            log_info "正在拉取最新代码更新..."
            deploy_core
            systemctl restart "$SVC_NAME"
            log_info "Argo 已更新至最新版本并重启！"
            ;;
        uninstall) uninstall_argo ;;
        help|-h|--help) show_help ;;
        *)
            show_help
            ;;
    esac
else
    while true; do
        main_menu
        echo -e "\n按任意键返回主菜单..."
        read -n 1 -s -r
    done
fi
