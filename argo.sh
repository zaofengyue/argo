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

# ── 首次极速安装向导 (仅交互核心 1~4 项，5~8 项默认预设) ─────────────────────
quick_install_wizard() {
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${WHITE}           🚀 Argo 服务端初始化配置${NC}"
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
    echo -e "${WHITE}1. 核心 UUID${NC} (回车默认: ${GREEN}${def_uuid}${NC})"
    read -rp "   请输入 UUID: " input_uuid
    local final_uuid="${input_uuid:-$def_uuid}"
    set_env "UUID" "$final_uuid"

    # 2. 独立密码
    local def_pwd
    def_pwd=$(get_env "PASSWORD")
    [[ -z "$def_pwd" ]] && def_pwd="$final_uuid"
    echo -e "\n${WHITE}2. Trojan 密码${NC} (回车默认复用 UUID: ${GREEN}${final_uuid}${NC})"
    read -rp "   请输入密码: " input_pwd
    set_env "PASSWORD" "${input_pwd:-$def_pwd}"

    # 3. 内部端口
    local def_port
    def_port=$(get_env "PORT")
    [[ -z "$def_port" ]] && def_port="3000"
    echo -e "\n${WHITE}3. 本地监听端口${NC} (回车默认: ${GREEN}${def_port}${NC})"
    read -rp "   请输入端口: " input_port
    set_env "PORT" "${input_port:-$def_port}"

    # 4. 节点名称
    local def_name
    def_name=$(get_env "NAME")
    echo -e "\n${WHITE}4. 节点标识名称${NC} (回车默认: ${GREEN}自动探测 国家-运营商${NC})"
    read -rp "   请输入节点名称 (留空自动探测): " input_name
    set_env "NAME" "${input_name:-$def_name}"

    # 5/6/7/8 自动预设默认值，初次安装不在界面打扰，高级配置可进菜单修改
    [[ -z "$(get_env "ARGO_DOMAIN")" ]] && set_env "ARGO_DOMAIN" ""
    [[ -z "$(get_env "ARGO_AUTH")" ]] && set_env "ARGO_AUTH" ""
    [[ -z "$(get_env "CF_PREFER_HOST")" ]] && set_env "CF_PREFER_HOST" "www.visa.com.tw"
    [[ -z "$(get_env "SUB")" ]] && set_env "SUB" "sub"

    log_info "基础参数已配置完毕！高级项可在“修改配置”菜单中随时调整。"
}

# ── 修改配置子菜单 (单项直选修改，留空不改) ──────────────────────────────────
config_menu() {
    local modified=0
    while true; do
        clear
        local cur_uuid cur_pwd cur_port cur_name cur_domain cur_auth cur_cf cur_tg_token cur_tg_chat cur_km_domain cur_km_token
        cur_uuid=$(get_env "UUID")
        [[ -z "$cur_uuid" ]] && cur_uuid="a982ac5f-9acd-4d38-9140-56f0b27c6961"
        cur_pwd=$(get_env "PASSWORD")
        [[ -z "$cur_pwd" ]] && cur_pwd="$cur_uuid"
        cur_port=$(get_env "PORT")
        [[ -z "$cur_port" ]] && cur_port="3000"
        cur_name=$(get_env "NAME")
        [[ -z "$cur_name" ]] && cur_name="自动探测"
        cur_domain=$(get_env "ARGO_DOMAIN")
        [[ -z "$cur_domain" ]] && cur_domain="未配置"
        cur_auth=$(get_env "ARGO_AUTH")
        if [[ -n "$cur_auth" ]]; then
            cur_auth="${cur_auth:0:6}...${cur_auth: -4}"
        else
            cur_auth="未配置"
        fi
        cur_cf=$(get_env "CF_PREFER_HOST")
        [[ -z "$cur_cf" ]] && cur_cf="www.visa.com.tw"

        cur_tg_token=$(get_env "TG_BOT_TOKEN")
        cur_tg_chat=$(get_env "TG_CHAT_ID")
        local cur_tg="未配置"
        [[ -n "$cur_tg_token" && -n "$cur_tg_chat" ]] && cur_tg="已配置"

        cur_km_domain=$(get_env "KOMARI_DOMAIN")
        cur_km_token=$(get_env "KOMARI_TOKEN")
        local cur_km="未配置"
        [[ -n "$cur_km_domain" && -n "$cur_km_token" ]] && cur_km="已配置 (${cur_km_domain})"

        echo -e "${CYAN}====================================================${NC}"
        echo -e "${WHITE}                  ⚙️  修改配置${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo -e " ${GREEN}1.${NC} 核心 UUID      : ${CYAN}${cur_uuid}${NC}"
        echo -e " ${GREEN}2.${NC} Trojan 密码    : ${CYAN}${cur_pwd}${NC}"
        echo -e " ${GREEN}3.${NC} 本地监听端口   : ${CYAN}${cur_port}${NC}"
        echo -e " ${GREEN}4.${NC} 节点标识名称   : ${CYAN}${cur_name}${NC}"
        echo -e " ${GREEN}5.${NC} Argo 固定域名  : ${CYAN}${cur_domain}${NC}"
        echo -e " ${GREEN}6.${NC} Argo 隧道凭证  : ${CYAN}${cur_auth}${NC}"
        echo -e " ${GREEN}7.${NC} CF 优选域名    : ${CYAN}${cur_cf}${NC}"
        echo -e " ${GREEN}8.${NC} TG 推送设置    : ${CYAN}${cur_tg}${NC}"
        echo -e " ${GREEN}9.${NC} Komari 探针    : ${CYAN}${cur_km}${NC}"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e " ${WHITE}0.${NC} 返回主菜单"
        echo -e "${CYAN}====================================================${NC}"
        read -rp "请输入要修改的配置项 [0-9]: " cfg_choice

        case "$cfg_choice" in
            1)
                echo -e "\n当前 UUID: ${GREEN}${cur_uuid}${NC}"
                read -rp "请输入新的 UUID (留空保持原值): " new_val
                if [[ -n "$new_val" ]]; then
                    set_env "UUID" "$new_val"
                    modified=1
                fi
                ;;
            2)
                echo -e "\n当前密码: ${GREEN}${cur_pwd}${NC}"
                read -rp "请输入新的 Trojan 密码 (留空保持原值): " new_val
                if [[ -n "$new_val" ]]; then
                    set_env "PASSWORD" "$new_val"
                    modified=1
                fi
                ;;
            3)
                echo -e "\n当前端口: ${GREEN}${cur_port}${NC}"
                read -rp "请输入新的本地监听端口 (留空保持原值): " new_val
                if [[ -n "$new_val" ]]; then
                    set_env "PORT" "$new_val"
                    modified=1
                fi
                ;;
            4)
                echo -e "\n当前节点名称: ${GREEN}${cur_name}${NC}"
                read -rp "请输入新的节点标识 (输入 'none' 清空为自动探测，留空保持原值): " new_val
                if [[ "$new_val" == "none" ]]; then
                    set_env "NAME" ""
                    modified=1
                elif [[ -n "$new_val" ]]; then
                    set_env "NAME" "$new_val"
                    modified=1
                fi
                ;;
            5)
                echo -e "\n当前固定域名: ${GREEN}${cur_domain}${NC}"
                read -rp "请输入新的 Argo 固定域名 (输入 'none' 改为临时隧道，留空保持原值): " new_val
                if [[ "$new_val" == "none" ]]; then
                    set_env "ARGO_DOMAIN" ""
                    modified=1
                elif [[ -n "$new_val" ]]; then
                    set_env "ARGO_DOMAIN" "$new_val"
                    modified=1
                fi
                ;;
            6)
                echo -e "\n当前凭证: ${GREEN}${cur_auth}${NC}"
                read -rp "请输入 Cloudflare Tunnel Token (输入 'none' 清空，留空保持原值): " new_val
                if [[ "$new_val" == "none" ]]; then
                    set_env "ARGO_AUTH" ""
                    modified=1
                elif [[ -n "$new_val" ]]; then
                    set_env "ARGO_AUTH" "$new_val"
                    modified=1
                fi
                ;;
            7)
                echo -e "\n当前优选域名: ${GREEN}${cur_cf}${NC}"
                read -rp "请输入 CF 优选域名或 IP (输入 'none' 恢复默认，留空保持原值): " new_val
                if [[ "$new_val" == "none" ]]; then
                    set_env "CF_PREFER_HOST" "www.visa.com.tw"
                    modified=1
                elif [[ -n "$new_val" ]]; then
                    set_env "CF_PREFER_HOST" "$new_val"
                    modified=1
                fi
                ;;
            8)
                echo -e "\n当前 TG 推送: ${GREEN}${cur_tg}${NC}"
                read -rp "请输入 TG_BOT_TOKEN (输入 'none' 关闭推送，留空保持原值): " new_bot
                if [[ "$new_bot" == "none" ]]; then
                    set_env "TG_BOT_TOKEN" ""
                    set_env "TG_CHAT_ID" ""
                    modified=1
                elif [[ -n "$new_bot" ]]; then
                    read -rp "请输入 TG_CHAT_ID: " new_chat
                    set_env "TG_BOT_TOKEN" "$new_bot"
                    set_env "TG_CHAT_ID" "$new_chat"
                    modified=1
                fi
                ;;
            9)
                echo -e "\n当前 Komari 探针: ${GREEN}${cur_km}${NC}"
                read -rp "请输入 Komari 服务端域名 (输入 'none' 关闭探针，留空保持原值): " new_domain
                if [[ "$new_domain" == "none" ]]; then
                    set_env "KOMARI_DOMAIN" ""
                    set_env "KOMARI_TOKEN" ""
                    modified=1
                elif [[ -n "$new_domain" ]]; then
                    read -rp "请输入 Komari 探针 Token: " new_token
                    set_env "KOMARI_DOMAIN" "$new_domain"
                    set_env "KOMARI_TOKEN" "$new_token"
                    modified=1
                fi
                ;;
            0)
                if [[ "$modified" -eq 1 ]]; then
                    systemctl restart "$SVC_NAME" >/dev/null 2>&1 || true
                    log_info "配置已修改，Argo 服务已自动重启生效！"
                    sleep 1.5
                fi
                break
                ;;
            *)
                log_error "无效选项，请输入 0-9 之间的数字！"
                sleep 1
                ;;
        esac
    done
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

    # 下载最新实体脚本并更新全局快捷命令 (同时支持 argo 与短命令 ag)
    curl -fsSL -H "Cache-Control: no-cache" "${REPO_RAW}/argo.sh" -o "$APP_DIR/argo.sh" 2>/dev/null || true
    chmod +x "$APP_DIR/argo.sh"
    ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
    chmod +x "$BIN_LINK" 2>/dev/null || true
    ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
    chmod +x "/usr/local/bin/ag" 2>/dev/null || true
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
    echo -e " ${GREEN}1.${NC} 安装 Argo"
    echo -e " ${GREEN}2.${NC} 启动服务"
    echo -e " ${GREEN}3.${NC} 停止服务"
    echo -e " ${GREEN}4.${NC} 重启服务"
    echo -e " ${GREEN}5.${NC} 查看节点"
    echo -e " ${GREEN}6.${NC} 查看日志"
    echo -e " ${GREEN}7.${NC} 修改配置"
    echo -e " ${GREEN}8.${NC} 更新脚本"
    echo -e " ${RED}9.${NC} 卸载 Argo"
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
            quick_install_wizard
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
            config_menu
            ;;
        8)
            check_root
            log_info "正在从 GitHub 拉取最新脚本与服务端核心..."
            curl -fsSL -H "Cache-Control: no-cache" "${REPO_RAW}/argo.sh" -o "$APP_DIR/argo.sh" 2>/dev/null || true
            chmod +x "$APP_DIR/argo.sh"
            ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
            ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
            deploy_core
            systemctl restart "$SVC_NAME" >/dev/null 2>&1 || true
            log_info "Argo 脚本与核心已成功更新至最新版本！"
            echo -e "\n按任意键重新载入最新菜单..."
            read -n 1 -s -r
            exec bash "$APP_DIR/argo.sh"
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

# 预置实体脚本与全局快捷命令 (确保无论是否已安装，argo 与 ag 均立即可用)
init_shortcut() {
    mkdir -p "$APP_DIR"
    if [[ ! -s "$APP_DIR/argo.sh" || "$0" == /dev/fd/* || "$0" == /proc/* ]]; then
        curl -fsSL -H "Cache-Control: no-cache" "${REPO_RAW}/argo.sh" -o "$APP_DIR/argo.sh" 2>/dev/null || true
        chmod +x "$APP_DIR/argo.sh" 2>/dev/null || true
    fi
    if [[ -s "$APP_DIR/argo.sh" ]]; then
        ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
        chmod +x "$BIN_LINK" 2>/dev/null || true
        ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
        chmod +x "/usr/local/bin/ag" 2>/dev/null || true
    fi
}
init_shortcut

if [[ -n "$1" ]]; then
    case "$1" in
        install)
            check_systemd
            install_dependencies
            ensure_nodejs
            quick_install_wizard
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
            config_menu
            ;;
        update|upgrade)
            log_info "正在拉取最新代码更新..."
            curl -fsSL -H "Cache-Control: no-cache" "${REPO_RAW}/argo.sh" -o "$APP_DIR/argo.sh" 2>/dev/null || true
            chmod +x "$APP_DIR/argo.sh"
            ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
            ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
            deploy_core
            systemctl restart "$SVC_NAME" >/dev/null 2>&1 || true
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
