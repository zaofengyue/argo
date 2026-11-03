#!/usr/bin/env bash
# ==============================================================================
# Argo - Zero-Binary 纯原生代理服务端一键管理脚本
# GitHub: https://github.com/zaofengyue/argo
# ==============================================================================

# Alpine ash 兼容性处理：若当前不是 bash 则尝试唤起或自动安装 bash
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    elif [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && command -v apk >/dev/null 2>&1; then
        echo "检测到 Alpine 系统，自动安装 bash 与基础工具..."
        apk update >/dev/null 2>&1 || true
        apk add --no-cache bash >/dev/null 2>&1 || true
        exec bash "$0" "$@"
    else
        echo "本脚本需要 bash 才能运行，当前系统未检测到 bash。"
        exit 1
    fi
fi

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
SVC_SYSTEMD="/etc/systemd/system/${SVC_NAME}.service"
SVC_OPENRC="/etc/init.d/${SVC_NAME}"
OPENRC_LOG="/var/log/argo.log"
BIN_LINK="/usr/local/bin/argo"
REPO_RAW="https://raw.githubusercontent.com/zaofengyue/argo/main"

# ── 日志工具 ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 下载双引擎容灾封装 (curl / wget 互备) ──────────────────────────────────────
fetch_file() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H "Cache-Control: no-cache" "$url" -o "$dest" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --no-cache -O "$dest" "$url" 2>/dev/null
    else
        return 1
    fi
}

# ── 本地端口可用性检测 ────────────────────────────────────────────────────────
check_port_available() {
    local port="$1"
    [[ -z "$port" ]] && return 0
    local argo_pid
    argo_pid=$(pgrep -f "node index.js" | head -1)

    if command -v ss >/dev/null 2>&1; then
        local line
        line=$(ss -tlnp 2>/dev/null | grep -E ":${port}\s+")
        if [[ -n "$line" ]]; then
            if [[ -n "$argo_pid" ]] && echo "$line" | grep -q "pid=${argo_pid},"; then
                return 0
            fi
            return 1
        fi
    elif command -v lsof >/dev/null 2>&1; then
        local pid
        pid=$(lsof -t -i :"$port" 2>/dev/null | head -1)
        if [[ -n "$pid" ]]; then
            if [[ -n "$argo_pid" && "$pid" == "$argo_pid" ]]; then
                return 0
            fi
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        local line
        line=$(netstat -tulpn 2>/dev/null | grep -E ":${port}\s+")
        if [[ -n "$line" ]]; then
            if [[ -n "$argo_pid" ]] && echo "$line" | grep -q "${argo_pid}/"; then
                return 0
            fi
            return 1
        fi
    fi
    return 0
}

# ── 权限与系统检查 ────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "本脚本需要 root 权限运行，请使用 sudo -i 或切换为 root 用户后执行！"
        exit 1
    fi
}

INIT_TYPE=""
check_init_system() {
    if command -v systemctl >/dev/null 2>&1; then
        INIT_TYPE="systemd"
    elif command -v rc-service >/dev/null 2>&1 || [ -f /etc/alpine-release ]; then
        INIT_TYPE="openrc"
    else
        log_error "当前系统既不支持 systemd 也不支持 OpenRC，本脚本暂不支持当前环境！"
        exit 1
    fi
}

# ── 服务操作封装 (兼容 systemd 与 OpenRC) ──────────────────────────────────────
svc_start() {
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        systemctl start "$SVC_NAME"
    elif [[ "$INIT_TYPE" == "openrc" ]]; then
        rc-service "$SVC_NAME" start
    fi
}

svc_stop() {
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        systemctl stop "$SVC_NAME"
    elif [[ "$INIT_TYPE" == "openrc" ]]; then
        rc-service "$SVC_NAME" stop
    fi
}

svc_restart() {
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        systemctl restart "$SVC_NAME"
    elif [[ "$INIT_TYPE" == "openrc" ]]; then
        rc-service "$SVC_NAME" restart 2>/dev/null || { rc-service "$SVC_NAME" stop >/dev/null 2>&1; rc-service "$SVC_NAME" start; }
    fi
}

svc_is_active() {
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        systemctl is-active --quiet "$SVC_NAME"
    elif [[ "$INIT_TYPE" == "openrc" ]]; then
        rc-service "$SVC_NAME" status 2>/dev/null | grep -q "started"
    else
        return 1
    fi
}

# ── 纯 IPv6 临时 NAT64/DNS64 辅助挂载 ──────────────────────────────────────────
_NAT64_APPLIED=0
_NAT64_TARGET_CONF=""
_NAT64_ORIG_CONTENT=""

nat64_recover_leftover() {
    [ -f /etc/resolv.conf.sb-orig ] || return 0
    local _rc="/etc/resolv.conf"
    [ -L "$_rc" ] && _rc="$(readlink -f "$_rc" 2>/dev/null || echo "/etc/resolv.conf")"
    if [ -w "$_rc" ] && grep -q "2a01:4f8:c2c:123f::1" "$_rc" 2>/dev/null; then
        cat /etc/resolv.conf.sb-orig > "$_rc" 2>/dev/null || true
    fi
    rm -f /etc/resolv.conf.sb-orig 2>/dev/null || true
}

nat64_enable_temp() {
    local _probed="${1:-0}"
    [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
    nat64_recover_leftover
    local _has_v4=0
    if command -v ip >/dev/null 2>&1; then
        ip -4 route show default 2>/dev/null | grep -q default && _has_v4=1
    elif command -v route >/dev/null 2>&1; then
        route -n 2>/dev/null | grep -q '^0.0.0.0' && _has_v4=1
    fi
    [ "$_has_v4" = "1" ] && return 0

    if [ "$_probed" != "1" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -s --connect-timeout 2 -m 3 https://api.github.com >/dev/null 2>&1 && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --spider --timeout=3 -t 1 https://api.github.com >/dev/null 2>&1 && return 0
        fi
    fi

    local _rc="/etc/resolv.conf"
    [ -e "$_rc" ] || return 0
    if [ -L "$_rc" ]; then
        _rc="$(readlink -f "$_rc" 2>/dev/null || echo "/etc/resolv.conf")"
    fi
    [ -w "$_rc" ] || return 0

    local _n1="2a01:4f8:c2c:123f::1" _n2="2001:67c:2b0::4"
    if ! grep -q "$_n1" "$_rc" 2>/dev/null && ! grep -q "$_n2" "$_rc" 2>/dev/null; then
        cp -f "$_rc" /etc/resolv.conf.sb-orig 2>/dev/null || return 0
        trap 'nat64_restore_temp' EXIT
        trap 'nat64_restore_temp; exit 130' INT
        trap 'nat64_restore_temp; exit 143' TERM
        trap 'nat64_restore_temp; exit 129' HUP
        _NAT64_TARGET_CONF="$_rc"
        _NAT64_ORIG_CONTENT="$(cat "$_rc" 2>/dev/null)"
        log_info "检测到纯 IPv6 环境无法直连 GitHub，正在临时挂载公共 NAT64/DNS64 辅助网络通信..."
        printf 'nameserver %s\nnameserver %s\n%s\n' "$_n1" "$_n2" "$_NAT64_ORIG_CONTENT" > "$_rc" 2>/dev/null || true
        _NAT64_APPLIED=1
    fi
}

nat64_restore_temp() {
    if [ "$_NAT64_APPLIED" = "1" ] && [ -n "$_NAT64_TARGET_CONF" ] && [ -w "$_NAT64_TARGET_CONF" ]; then
        if [ -f /etc/resolv.conf.sb-orig ]; then
            cat /etc/resolv.conf.sb-orig > "$_NAT64_TARGET_CONF" 2>/dev/null || true
        elif [ -n "$_NAT64_ORIG_CONTENT" ]; then
            printf '%s\n' "$_NAT64_ORIG_CONTENT" > "$_NAT64_TARGET_CONF" 2>/dev/null || true
        fi
        rm -f /etc/resolv.conf.sb-orig 2>/dev/null || true
        trap - EXIT INT TERM HUP
    fi
    _NAT64_APPLIED=0
    _NAT64_TARGET_CONF=""
    _NAT64_ORIG_CONTENT=""
}

# ── 包管理器探测与依赖安装 ───────────────────────────────────────────────────
install_dependencies() {
    nat64_enable_temp
    log_info "正在检测并安装基础依赖 (curl, wget, tar, git, ca-certificates)..."
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add --no-cache curl wget tar git ca-certificates openssl procps bash nodejs npm
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        apt-get install -y curl wget tar git ca-certificates openssl procps
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget tar git ca-certificates openssl procps-ng
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget tar git ca-certificates openssl procps-ng
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget tar git ca-certificates openssl procps-ng
    fi
}

# ── Node.js 运行时探测与自动安装 ─────────────────────────────────────────────
ensure_nodejs() {
    nat64_enable_temp
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
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache nodejs npm
        elif command -v apt-get >/dev/null 2>&1; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            else
                wget -qO- https://deb.nodesource.com/setup_20.x | bash -
            fi
            apt-get install -y nodejs
        elif command -v dnf >/dev/null 2>&1; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            else
                wget -qO- https://rpm.nodesource.com/setup_20.x | bash -
            fi
            dnf install -y nodejs
        elif command -v yum >/dev/null 2>&1; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            else
                wget -qO- https://rpm.nodesource.com/setup_20.x | bash -
            fi
            yum install -y nodejs
        fi

        if ! command -v node >/dev/null 2>&1; then
            log_error "Node.js 自动安装失败，请手动安装 Node.js 18+ 后重新运行脚本！"
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

# ── 极速安装向导 (支持交互式与环境变量无人值守两种模式) ───────────────────────
quick_install_wizard() {
    echo -e "\n${CYAN}====================================================${NC}"
    echo -e "${WHITE}           🚀 Argo 服务端初始化配置${NC}"
    echo -e "${CYAN}====================================================${NC}\n"

    local is_unattended=0
    if [[ -n "${UUID:-}" || -n "${PASSWORD:-}" || -n "${PORT:-}" || -n "${NAME:-}" || -n "${ARGO_DOMAIN:-}" || -n "${ARGO_AUTH:-}" || -n "${CF_PREFER_HOST:-}" || -n "${KOMARI_DOMAIN:-}" ]]; then
        is_unattended=1
        log_info "检测到外部传入的环境变量，启用无人值守静默配置模式..."
    fi

    # 1. 核心 UUID
    local def_uuid="${UUID:-$(get_env "UUID")}"
    if [[ -z "$def_uuid" ]]; then
        if command -v uuidgen >/dev/null 2>&1; then
            def_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
        else
            def_uuid="a982ac5f-9acd-4d38-9140-56f0b27c6961"
        fi
    fi

    local final_uuid
    if [[ "$is_unattended" -eq 1 ]]; then
        final_uuid="$def_uuid"
        echo -e "${WHITE}1. 核心 UUID      :${NC} ${GREEN}${final_uuid}${NC}"
    else
        echo -e "${WHITE}1. 核心 UUID${NC} (回车默认: ${GREEN}自动生成${NC})"
        read -rp "   请输入 UUID: " input_uuid
        final_uuid="${input_uuid:-$def_uuid}"
    fi
    set_env "UUID" "$final_uuid"

    # 2. 独立密码
    local def_pwd="${PASSWORD:-$(get_env "PASSWORD")}"
    [[ -z "$def_pwd" ]] && def_pwd="$final_uuid"

    local final_pwd
    if [[ "$is_unattended" -eq 1 ]]; then
        final_pwd="$def_pwd"
        echo -e "${WHITE}2. Trojan 密码    :${NC} ${GREEN}${final_pwd}${NC}"
    else
        echo -e "\n${WHITE}2. Trojan 密码${NC} (回车默认: ${GREEN}复用UUID${NC})"
        read -rp "   请输入密码: " input_pwd
        final_pwd="${input_pwd:-$def_pwd}"
    fi
    set_env "PASSWORD" "$final_pwd"

    # 3. 内部端口
    local def_port="${PORT:-$(get_env "PORT")}"
    [[ -z "$def_port" ]] && def_port="3000"

    local final_port
    if [[ "$is_unattended" -eq 1 ]]; then
        final_port="$def_port"
        echo -e "${WHITE}3. 本地监听端口   :${NC} ${GREEN}${final_port}${NC}"
        if ! check_port_available "$final_port"; then
            log_warn "检测到端口 ${final_port} 已被系统其他程序占用，启动时可能冲突！"
        fi
    else
        echo -e "\n${WHITE}3. 本地监听端口${NC} (回车默认: ${GREEN}${def_port}${NC})"
        read -rp "   请输入端口: " input_port
        final_port="${input_port:-$def_port}"
        if ! check_port_available "$final_port"; then
            log_warn "检测到端口 ${final_port} 已被系统其他程序占用，启动时可能冲突！"
        fi
    fi
    set_env "PORT" "$final_port"

    # 4. 节点名称
    local def_name="${NAME:-$(get_env "NAME")}"

    local final_name
    if [[ "$is_unattended" -eq 1 ]]; then
        final_name="$def_name"
        echo -e "${WHITE}4. 节点标识名称   :${NC} ${GREEN}${final_name:-自动探测}${NC}"
    else
        echo -e "\n${WHITE}4. 节点标识名称${NC} (回车默认: ${GREEN}自动探测${NC})"
        read -rp "   请输入节点名称: " input_name
        final_name="${input_name:-$def_name}"
    fi
    set_env "NAME" "$final_name"

    # 5/6/7/8 高级项处理 (支持外部环境变量直接注入，未传则保留原值或使用默认值)
    local cur_argo_dom="${ARGO_DOMAIN:-$(get_env "ARGO_DOMAIN")}"
    set_env "ARGO_DOMAIN" "$cur_argo_dom"

    local cur_argo_auth="${ARGO_AUTH:-$(get_env "ARGO_AUTH")}"
    set_env "ARGO_AUTH" "$cur_argo_auth"

    local cur_cf="${CF_PREFER_HOST:-$(get_env "CF_PREFER_HOST")}"
    [[ -z "$cur_cf" ]] && cur_cf="www.visa.com.tw"
    set_env "CF_PREFER_HOST" "$cur_cf"

    local cur_sub="${SUB:-$(get_env "SUB")}"
    [[ -z "$cur_sub" ]] && cur_sub="sub"
    set_env "SUB" "$cur_sub"

    local cur_log_clear="${LOG_CLEAR_MINUTES:-$(get_env "LOG_CLEAR_MINUTES")}"
    [[ -z "$cur_log_clear" ]] && cur_log_clear="0"
    set_env "LOG_CLEAR_MINUTES" "$cur_log_clear"

    local cur_km_dom="${KOMARI_DOMAIN:-$(get_env "KOMARI_DOMAIN")}"
    set_env "KOMARI_DOMAIN" "$cur_km_dom"

    local cur_km_tok="${KOMARI_TOKEN:-$(get_env "KOMARI_TOKEN")}"
    set_env "KOMARI_TOKEN" "$cur_km_tok"

    if [[ "$is_unattended" -eq 1 ]]; then
        [[ -n "$cur_argo_dom" ]] && echo -e "${WHITE}5. Argo 固定域名  :${NC} ${GREEN}${cur_argo_dom}${NC}"
        [[ -n "$cur_argo_auth" ]] && echo -e "${WHITE}6. Argo 隧道凭证  :${NC} ${GREEN}已设置${NC}"
        echo -e "${WHITE}7. CF 优选域名    :${NC} ${GREEN}${cur_cf}${NC}"
        [[ -n "$cur_km_dom" ]] && echo -e "${WHITE}8. Komari 探针    :${NC} ${GREEN}${cur_km_dom}${NC}"
    fi

    log_info "基础参数已配置完毕！"
}

# ── 修改配置子菜单 (单项直选修改，留空不改) ──────────────────────────────────
config_menu() {
    local modified=0
    while true; do
        clear
        local cur_uuid cur_pwd cur_port cur_name cur_domain cur_auth cur_cf cur_km_domain cur_km_token
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
        echo -e " ${GREEN}8.${NC} Komari 探针    : ${CYAN}${cur_km}${NC}"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e " ${WHITE}0.${NC} 返回主菜单"
        echo -e "${CYAN}====================================================${NC}"
        read -rp "请输入要修改的配置项 [0-8]: " cfg_choice

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
                    if ! check_port_available "$new_val"; then
                        log_warn "检测到端口 ${new_val} 已被系统其他程序占用，启动时可能冲突！"
                    fi
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
                    svc_restart >/dev/null 2>&1 || true
                    log_info "配置已修改，Argo 服务已自动重启生效！"
                    sleep 1.5
                fi
                break
                ;;
            *)
                log_error "无效选项，请输入 0-8 之间的数字！"
                sleep 1
                ;;
        esac
    done
}

# ── 安装 / 更新核心代码 ───────────────────────────────────────────────────────
deploy_core() {
    nat64_enable_temp
    log_info "正在配置 Argo 核心目录: ${APP_DIR}..."
    mkdir -p "$APP_DIR/nodejs"

    log_info "正在获取最新 Argo 服务端代码..."
    fetch_file "${REPO_RAW}/nodejs/index.js" "$APP_DIR/nodejs/index.js"
    fetch_file "${REPO_RAW}/nodejs/package.json" "$APP_DIR/nodejs/package.json"
    fetch_file "${REPO_RAW}/nodejs/index.html" "$APP_DIR/nodejs/index.html"

    log_info "正在安装 Node.js 依赖..."
    cd "$APP_DIR/nodejs" || exit 1
    npm install --omit=dev --silent

    # 下载最新实体脚本并更新全局快捷命令 (同时支持 argo 与短命令 ag)
    fetch_file "${REPO_RAW}/argo.sh" "$APP_DIR/argo.sh" || true
    chmod +x "$APP_DIR/argo.sh" 2>/dev/null || true
    ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
    chmod +x "$BIN_LINK" 2>/dev/null || true
    ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
    chmod +x "/usr/local/bin/ag" 2>/dev/null || true
}

# ── 注册系统守护服务 (支持 Systemd 与 OpenRC) ─────────────────────────────────
install_service() {
    local node_bin
    node_bin=$(command -v node)

    if [[ "$INIT_TYPE" == "systemd" ]]; then
        log_info "正在注册 systemd 系统守护服务 (${SVC_NAME})..."
        cat > "$SVC_SYSTEMD" <<EOF
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
    elif [[ "$INIT_TYPE" == "openrc" ]]; then
        log_info "正在注册 OpenRC 系统守护服务 (${SVC_NAME})..."
        cat > "$SVC_OPENRC" <<EOF
#!/sbin/openrc-run

name="argo"
description="Argo Zero-Binary Proxy Service"
directory="${APP_DIR}/nodejs"
pidfile="/run/argo.pid"
command="${node_bin}"
command_args="index.js"
command_background="yes"
output_log="${OPENRC_LOG}"
error_log="${OPENRC_LOG}"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -d -m 0755 /run
    if [ -f "${ENV_FILE}" ]; then
        set -a
        . "${ENV_FILE}"
        set +a
    fi
}
EOF
        chmod +x "$SVC_OPENRC"
        rc-update add "$SVC_NAME" default >/dev/null 2>&1
        rc-service "$SVC_NAME" stop >/dev/null 2>&1 || true
        rc-service "$SVC_NAME" start
        log_info "Argo 服务已通过 OpenRC 启动并设置开机自启！"
    fi
}

# ── 运行状态查询 ──────────────────────────────────────────────────────────────
check_status() {
    if svc_is_active; then
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

# ── 提取临时穿透域名 ──────────────────────────────────────────────────────────
extract_temp_domain() {
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        journalctl -u "$SVC_NAME" --no-pager -n 50 2>/dev/null | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1
    else
        grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$OPENRC_LOG" 2>/dev/null | tail -1
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

    # 获取穿透域名 (固定隧道直接使用配置，临时隧道则智能轮询日志提取)
    local domain=""
    local fixed_domain
    fixed_domain=$(get_env "ARGO_DOMAIN")

    if [[ -n "$fixed_domain" ]]; then
        domain="https://${fixed_domain}"
    else
        domain=$(extract_temp_domain)
        if [[ -z "$domain" ]] && svc_is_active; then
            echo -ne "${YELLOW}正在等待 Cloudflare Argo 临时穿透隧道就绪...${NC}"
            local retry=0
            while [[ -z "$domain" && $retry -lt 8 ]]; do
                sleep 1
                echo -ne "."
                domain=$(extract_temp_domain)
                ((retry++))
            done
            echo -e ""
        fi
    fi

    if [[ -n "$domain" ]]; then
        local sub_path
        sub_path=$(get_env "SUB")
        [[ -z "$sub_path" ]] && sub_path="sub"
        echo -e "穿透地址: ${WHITE}${domain}${NC}"
        echo -e "订阅链接: ${GREEN}${domain}/${sub_path}${NC}"
    else
        echo -e "${YELLOW}服务已启动，隧道建立中，请稍后输入 argo sub 查询最新域名。${NC}"
    fi
    echo -e "${CYAN}========================================================${NC}\n"
}

# ── 实时日志查看 ──────────────────────────────────────────────────────────────
view_logs() {
    echo -e "${YELLOW}按 Ctrl+C 退出实时日志查看...${NC}\n"
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        journalctl -u "$SVC_NAME" -f -n 50
    else
        touch "$OPENRC_LOG"
        tail -f -n 50 "$OPENRC_LOG"
    fi
}

# ── 完整部署执行流程 ──────────────────────────────────────────────────────────
do_install() {
    check_root
    check_init_system
    install_dependencies
    ensure_nodejs
    quick_install_wizard
    deploy_core
    install_service
    sleep 1
    show_subscription
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
    if [[ "$INIT_TYPE" == "systemd" ]]; then
        systemctl stop "$SVC_NAME" >/dev/null 2>&1
        systemctl disable "$SVC_NAME" >/dev/null 2>&1
        rm -f "$SVC_SYSTEMD"
        systemctl daemon-reload
    elif [[ "$INIT_TYPE" == "openrc" ]]; then
        rc-service "$SVC_NAME" stop >/dev/null 2>&1 || true
        rc-update del "$SVC_NAME" default >/dev/null 2>&1 || true
        rm -f "$SVC_OPENRC"
        rm -f /run/argo.pid
        rm -f "$OPENRC_LOG"
    fi

    pkill -f "bridge" 2>/dev/null || true
    pkill -f "metrics" 2>/dev/null || true
    pkill -f "node /app/bridge.js" 2>/dev/null || true
    pkill -f "node index.js" 2>/dev/null || true

    rm -rf "$APP_DIR"
    rm -f "$BIN_LINK"
    rm -f "/usr/local/bin/ag" 2>/dev/null || true
    rm -rf "$HOME/.argo-core"

    # 若残留 NAT64 注入，一并清理复原
    nat64_restore_temp
    nat64_recover_leftover

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
    echo -e " ${RED}2.${NC} 卸载 Argo"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " ${GREEN}3.${NC} 启动服务"
    echo -e " ${GREEN}4.${NC} 停止服务"
    echo -e " ${GREEN}5.${NC} 重启服务"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " ${GREEN}6.${NC} 查看节点"
    echo -e " ${GREEN}7.${NC} 查看日志"
    echo -e " ${GREEN}8.${NC} 修改配置"
    echo -e " ${GREEN}9.${NC} 更新脚本"
    echo -e "${CYAN}----------------------------------------------------${NC}"
    echo -e " ${WHITE}0.${NC} 退出脚本"
    echo -e "${CYAN}====================================================${NC}"
    read -rp "请输入数字 [0-9]: " choice

    case "$choice" in
        1)
            do_install
            ;;
        2)
            check_root
            uninstall_argo
            ;;
        3)
            check_root
            svc_start
            log_info "服务已启动。"
            ;;
        4)
            check_root
            svc_stop
            log_info "服务已停止。"
            ;;
        5)
            check_root
            svc_restart
            log_info "服务已重启。"
            ;;
        6)
            show_subscription
            ;;
        7)
            view_logs
            ;;
        8)
            check_root
            config_menu
            ;;
        9)
            check_root
            nat64_enable_temp
            log_info "正在从 GitHub 拉取最新脚本与服务端核心..."
            fetch_file "${REPO_RAW}/argo.sh" "$APP_DIR/argo.sh" || true
            chmod +x "$APP_DIR/argo.sh" 2>/dev/null || true
            ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
            ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
            deploy_core
            svc_restart >/dev/null 2>&1 || true
            log_info "Argo 脚本与核心已成功更新至最新版本！"
            echo -e "\n按任意键重新载入最新菜单..."
            read -n 1 -s -r
            exec bash "$APP_DIR/argo.sh"
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
    echo -e " ${GREEN}argo edit${NC}          - 修改核心参数 (UUID/密码/端口/隧道Token/CF优选)"
    echo -e " ${GREEN}argo update${NC}        - 一键检查并拉取更新服务端到最新版"
    echo -e " ${RED}argo uninstall${NC}     - 彻底卸载 Argo 服务与所有配置文件"
    echo -e " ${GREEN}argo help${NC}          - 显示本命令行帮助目录"
    echo -e "${CYAN}====================================================${NC}"
}

# ── 脚本入口 ──────────────────────────────────────────────────────────────────
check_root
check_init_system

# 预置实体脚本与全局快捷命令 (确保无论是否已安装，argo 与 ag 均立即可用)
init_shortcut() {
    nat64_enable_temp
    mkdir -p "$APP_DIR"
    if [[ ! -s "$APP_DIR/argo.sh" || "$0" == /dev/fd/* || "$0" == /proc/* ]]; then
        fetch_file "${REPO_RAW}/argo.sh" "$APP_DIR/argo.sh" || true
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
            do_install
            ;;
        menu)    main_menu ;;
        start)   svc_start; log_info "服务已启动。" ;;
        stop)    svc_stop; log_info "服务已停止。" ;;
        restart) svc_restart; log_info "服务已重启。" ;;
        status)  check_status ;;
        sub)     show_subscription ;;
        log)     view_logs ;;
        edit|config)
            config_menu
            ;;
        update|upgrade)
            nat64_enable_temp
            log_info "正在拉取最新代码更新..."
            fetch_file "${REPO_RAW}/argo.sh" "$APP_DIR/argo.sh" || true
            chmod +x "$APP_DIR/argo.sh" 2>/dev/null || true
            ln -sf "$APP_DIR/argo.sh" "$BIN_LINK" 2>/dev/null || true
            ln -sf "$APP_DIR/argo.sh" "/usr/local/bin/ag" 2>/dev/null || true
            deploy_core
            svc_restart >/dev/null 2>&1 || true
            log_info "Argo 已更新至最新版本并重启！"
            ;;
        uninstall) uninstall_argo ;;
        help|-h|--help) show_help ;;
        *)
            show_help
            ;;
    esac
else
    # 无参数时：若检测到传入了外部环境变量，则直接触发无人值守一键安装
    if [[ -n "${UUID:-}" || -n "${PASSWORD:-}" || -n "${PORT:-}" || -n "${NAME:-}" || -n "${ARGO_DOMAIN:-}" || -n "${ARGO_AUTH:-}" ]]; then
        do_install
        exit 0
    fi

    while true; do
        main_menu
        echo -e "\n按任意键返回主菜单..."
        read -n 1 -s -r
    done
fi
