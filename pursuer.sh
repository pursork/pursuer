#!/usr/bin/env bash
# pursuer.sh — VPS 工具箱主入口（薄调度层）
# 用法：
#   交互菜单：bash pursuer.sh
#   Termius Snippet：bash <(curl -fsSL URL) --setup
#   通用模块：bash <(curl -fsSL URL) --ssh-key

set -euo pipefail

# ── 仓库配置（唯一需要随迁移修改的地方）────────────────────────
: "${GITHUB_RAW:=https://raw.githubusercontent.com/pursork/pursuer/refs/heads/main}"
: "${SSH_PUBKEY_URL:=https://sshid.io/pursuer}"
: "${GITHUB_PUBKEY_URL:=https://github.com/pursork.keys}"
export GITHUB_RAW SSH_PUBKEY_URL GITHUB_PUBKEY_URL

# ── 最小打印工具（lib 加载前使用）──────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
_info() { echo -e "${GREEN}[OK]${NC} $*"; }
_err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── 加载 lib/common.sh ──────────────────────────────────────────
_load_common() {
    local _tmp
    _tmp=$(mktemp /tmp/pursuer_common_XXXXXX.sh)
    if ! curl -fsSL "${GITHUB_RAW}/lib/common.sh" -o "$_tmp" 2>/dev/null; then
        _err "无法加载 lib/common.sh"; rm -f "$_tmp"; exit 1
    fi
    # shellcheck source=/dev/null
    source "$_tmp"
    rm -f "$_tmp"
}

# ── 下载并 source 模块，调用 _module_main ────────────────────────
run_module() {
    local _mod="$1"; shift
    local _tmp
    _tmp=$(mktemp /tmp/pursuer_mod_XXXXXX.sh)
    if ! curl -fsSL "${GITHUB_RAW}/modules/${_mod}.sh" -o "$_tmp" 2>/dev/null; then
        error "无法加载模块 ${_mod}"; rm -f "$_tmp"; exit 1
    fi
    # shellcheck source=/dev/null
    source "$_tmp"
    rm -f "$_tmp"
    _module_main "$@"
}

# ── 帮助文本 ────────────────────────────────────────────────────
show_help() {
    echo "用法: pursuer.sh [选项]"
    echo ""
    echo "  --setup          VPS 初始化（从 myconf 私有仓库读取全部配置，首次必跑）"
    echo "  --ssh-key        配置 SSH 密钥登录 + Telegram 告警"
    echo "  --init-system    系统初始化（基础包/SSH端口/BBR/时区/NTP）"
    echo "  --tailscale      加入 Tailscale 内网（写入 WG_LISTEN_IP）"
    echo "  --dante          安装 Dante SOCKS5 代理（监听 tailscale0:12000）"
    echo "  --nginx          安装 Nginx"
    echo "  --acme           安装 acme.sh"
    echo "  --hysteria       安装 Hysteria2 代理"
    echo "  --xray           安装 Xray（VLESS + REALITY）"
    echo "  --tcp-tune       TCP 自动自检调优（可选，--init-system 之后任意时刻运行）"
    echo "  --update-proxy   从私有仓库更新代理配置"
    echo "  --port PORT      指定 SSH 端口"
    echo "  --tz   ZONE      指定时区（默认 Asia/Shanghai）"
    echo ""
    echo "推荐工作流（Termius Snippet）:"
    echo "  Step 0 — 每台 VPS 首次运行一次（per-VPS 定制 snippet）:"
    echo "    export DEPLOY_KEY='...' VPS_ID='sg01'"
    echo "    bash <(curl -fsSL ${GITHUB_RAW}/pursuer.sh) --setup"
    echo ""
    echo "  Step 1+ — 通用 snippet（参数自动从 /etc/pursuer.env 读取）:"
    echo "    bash <(curl -fsSL URL) --ssh-key"
    echo "    bash <(curl -fsSL URL) --init-system"
    echo "    bash <(curl -fsSL URL) --tailscale"
    echo "    bash <(curl -fsSL URL) --dante"
    echo "    bash <(curl -fsSL URL) --hysteria"
    echo "    bash <(curl -fsSL URL) --xray"
    echo ""
    echo "--setup 所需环境变量:"
    echo "  DEPLOY_KEY      myconf 私有仓库 Deploy Key（必填）"
    echo "  VPS_ID          VPS 标识符，对应 myconf/vps/<ID>.env（必填）"
    echo "  MYCONF_KNOWN_HOSTS  github.com 的 known_hosts 记录（首次拉取 myconf 时可用）"
    echo ""
    echo "myconf 配置模型:"
    echo "  vps/common.env  应包含 NEW_SSH_PORT / NEW_TIMEZONE / TG_* / CF_* / ACME_EMAIL / NZ_* / TS_AUTHKEY"
    echo "  vps/<ID>.env    应包含 VPS_NAME / HYS_DOMAIN / X_DOMAIN / NZ_UUID"
    echo "  WG_LISTEN_IP    由 --tailscale 在运行时写入 /etc/pursuer.env"
    exit 0
}

# ── 参数解析（非交互模式）──────────────────────────────────────
parse_args() {
    local action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port|-p)   export NEW_SSH_PORT="$2"; shift 2 ;;
            --port=*)    export NEW_SSH_PORT="${1#*=}"; shift ;;
            --tz|-t)     export NEW_TIMEZONE="$2"; shift 2 ;;
            --tz=*)      export NEW_TIMEZONE="${1#*=}"; shift ;;
            --setup|--ssh-key|--init-system|--tailscale|--dante|--nginx|--acme|--hysteria|--xray|--tcp-tune|--update-proxy)
                         action="$1"; shift ;;
            --help|-h)   show_help ;;
            *)           error "未知参数: $1"; exit 1 ;;
        esac
    done

    check_root
    case "$action" in
        --setup)        run_module "setup" ;;
        --ssh-key)      run_module "ssh_key" ;;
        --init-system)  run_module "init_system" ;;
        --tailscale)    run_module "tailscale" ;;
        --dante)        run_module "dante" ;;
        --nginx)        warn "nginx 模块尚未实现"; exit 0 ;;
        --acme)         warn "acme 模块尚未实现"; exit 0 ;;
        --hysteria)     run_module "hysteria" ;;
        --xray)         run_module "xray" ;;
        --tcp-tune)     run_module "tcp_tune" ;;
        --update-proxy) run_module "update_proxy" ;;
        "")             error "未指定操作，使用 --help 查看帮助"; exit 1 ;;
    esac
    exit 0
}

# ── 交互菜单 ────────────────────────────────────────────────────
show_menu() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════╗"
    echo "  ║       Pursuer VPS Toolbox            ║"
    echo "  ╚══════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}── 首次部署 ────────────────────────────${NC}"
    echo -e "  ${GREEN}1${NC}. VPS 初始化配置（从私有仓库读取全部参数）"
    echo ""
    echo -e "  ${BOLD}── 系统初始化 ──────────────────────────${NC}"
    echo -e "  ${GREEN}2${NC}. 配置 SSH 密钥登录"
    echo -e "  ${GREEN}3${NC}. 系统初始化（基础包 / SSH端口 / BBR / 时区 / NTP）"
    echo ""
    echo -e "  ${BOLD}── 软件安装 ────────────────────────────${NC}"
    echo -e "  ${GREEN}4${NC}. 安装 Tailscale 内网"
    echo -e "  ${GREEN}5${NC}. 安装 Dante SOCKS5 代理（tailscale0:12000）"
    echo -e "  ${GREEN}6${NC}. 安装 Nginx"
    echo -e "  ${GREEN}7${NC}. 安装 acme.sh（SSL 证书）"
    echo -e "  ${GREEN}8${NC}. 安装 Hysteria2 代理"
    echo -e "  ${GREEN}9${NC}. 安装 Xray（VLESS + REALITY）"
    echo ""
    echo -e "  ${BOLD}── 运维操作 ────────────────────────────${NC}"
    echo -e "  ${GREEN}t${NC}. TCP 自动自检调优（apply；可设 TCP_TUNE_ACTION=rollback 回滚）"
    echo -e "  ${GREEN}u${NC}. 更新代理配置（从私有仓库分发）"
    echo ""
    echo -e "  ${RED}0${NC}. 退出"
    echo ""
    echo -en "  请选择 [0-9/t/u]: "
}

# ── 主程序 ──────────────────────────────────────────────────────
main() {
    # 加载 per-VPS 持久化配置
    [[ -f /etc/pursuer.env ]] && source /etc/pursuer.env

    # --help 不需要加载 common.sh
    [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && show_help

    # 加载共享库
    _info "加载共享库..."
    _load_common

    # 有参数时走非交互流程
    if [[ $# -gt 0 ]]; then
        parse_args "$@"
        return
    fi

    # 无参数走交互菜单
    check_root
    while true; do
        show_menu
        read -r choice
        case "$choice" in
            1) confirm "确认执行 VPS 初始化配置？"  && run_module "setup" ;;
            2) confirm "确认配置 SSH 密钥登录？"    && run_module "ssh_key" ;;
            3) confirm "确认执行系统初始化？"       && run_module "init_system" ;;
            4) confirm "确认安装 Tailscale 内网？"           && run_module "tailscale" ;;
            5) confirm "确认安装 Dante SOCKS5 代理？"        && run_module "dante" ;;
            6) confirm "确认安装 Nginx？"                    && warn "nginx 模块尚未实现" ;;
            7) confirm "确认安装 acme.sh？"                  && warn "acme 模块尚未实现" ;;
            8) confirm "确认安装 Hysteria2？"                && run_module "hysteria" ;;
            9) confirm "确认安装 Xray？"                     && run_module "xray" ;;
            t) confirm "确认执行 TCP 自动调优？"              && run_module "tcp_tune" ;;
            u) confirm "确认更新代理配置？"                  && run_module "update_proxy" ;;
            0) echo "再见！"; exit 0 ;;
            *) warn "无效选项，请输入 0-9、t 或 u" ;;
        esac
        echo ""
        echo -en "${CYAN}按 Enter 返回菜单...${NC}"
        read -r
    done
}

main "$@"
