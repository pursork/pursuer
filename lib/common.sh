#!/usr/bin/env bash
# lib/common.sh — 共享工具函数库
# 由 pursuer.sh 下载后 source，不可直接执行

# ── 颜色 ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 打印工具 ─────────────────────────────────────────────────────
info()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
title()   { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
confirm() {
    local msg="${1:-确认执行？}"
    echo -en "${YELLOW}${msg} [y/N] ${NC}"
    read -r ans
    [[ "${ans,,}" == "y" ]]
}

# ── 权限检查 ─────────────────────────────────────────────────────
check_root() {
    [[ $EUID -eq 0 ]] && return 0
    error "此脚本需要 root 权限"
    exit 1
}

# ── 检查域名 DNS A 记录是否指向本机（warn 不中断）─────────────────
# 用法：check_dns_a <domain> <cf_token> <cf_zone_id>
check_dns_a() {
    local domain="$1" cf_token="$2" cf_zone_id="$3"
    local server_ip cf_ip

    server_ip=$(curl -fsSL https://api.ipify.org 2>/dev/null || true)
    if [[ -z "$server_ip" ]]; then
        warn "无法获取本机公网 IP，跳过 DNS A 记录检查"
        return 0
    fi

    cf_ip=$(curl -fsSL \
        "https://api.cloudflare.com/client/v4/zones/${cf_zone_id}/dns_records?type=A&name=${domain}" \
        -H "Authorization: Bearer ${cf_token}" \
        -H "Content-Type: application/json" 2>/dev/null \
        | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//;s/"//' || true)

    if [[ -z "$cf_ip" ]]; then
        warn "未在 Cloudflare 找到 ${domain} 的 A 记录，请添加后服务才可被访问"
    elif [[ "$cf_ip" != "$server_ip" ]]; then
        warn "DNS A 记录存在但指向 ${cf_ip}，本机 IP 为 ${server_ip}，请确认是否正确"
    else
        info "DNS A 记录已就绪：${domain} → ${server_ip}"
    fi
}

# ── 写入 /etc/pursuer.env（幂等）─────────────────────────────────
write_pursuer_env() {
    local key="$1" val="$2"
    touch /etc/pursuer.env
    sed -i "/^${key}=/d" /etc/pursuer.env
    echo "${key}=${val}" >> /etc/pursuer.env
}

# ── 设置 Deploy Key（从 DEPLOY_KEY 写入文件，幂等）───────────────
setup_deploy_key() {
    if [[ -f /root/.ssh/xconf_deploy ]]; then
        info "Deploy Key 已存在，跳过写入"
        return 0
    fi
    local deploy_key="${DEPLOY_KEY:-}"
    if [[ -z "$deploy_key" ]]; then
        error "未设置 DEPLOY_KEY 且本机无 /root/.ssh/xconf_deploy"
        return 1
    fi
    mkdir -p /root/.ssh
    echo "$deploy_key" > /root/.ssh/xconf_deploy
    chmod 600 /root/.ssh/xconf_deploy
    info "Deploy Key 已写入 → /root/.ssh/xconf_deploy"
}

# ── 确保 myconf 仓库的 SSH host key 已受信任 ───────────────────────
ensure_myconf_hostkey() {
    local known_hosts_file="/root/.ssh/known_hosts"
    local bootstrap_hosts="${MYCONF_KNOWN_HOSTS:-}"

    mkdir -p /root/.ssh
    touch "$known_hosts_file"
    chmod 600 "$known_hosts_file"

    if ssh-keygen -F github.com -f "$known_hosts_file" >/dev/null 2>&1 \
       || ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts >/dev/null 2>&1; then
        return 0
    fi

    if [[ -n "$bootstrap_hosts" ]]; then
        printf '%s\n' "$bootstrap_hosts" >> "$known_hosts_file"
        if ssh-keygen -F github.com -f "$known_hosts_file" >/dev/null 2>&1; then
            info "已通过 MYCONF_KNOWN_HOSTS 引导 github.com host key"
            return 0
        fi
        error "MYCONF_KNOWN_HOSTS 未包含 github.com 的有效 host key"
        return 1
    fi

    error "未找到 github.com 的受信任 host key"
    error "请先写入 /root/.ssh/known_hosts，或通过 MYCONF_KNOWN_HOSTS 提供"
    return 1
}

# ── 克隆或更新私有 myconf 仓库 ───────────────────────────────────
clone_or_pull_myconf() {
    ensure_myconf_hostkey || return 1
    export GIT_SSH_COMMAND="ssh -i /root/.ssh/xconf_deploy -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts"
    if [[ -d /root/myconf/.git ]]; then
        info "更新 myconf 仓库..."
        git -C /root/myconf pull
    elif [[ -d /root/myconf ]]; then
        error "/root/myconf 目录已存在但不是 git 仓库，请手动删除后重试"
        return 1
    else
        info "克隆 myconf 仓库..."
        git clone git@github.com:pursork/myconf.git /root/myconf
    fi
}

# ── 生成 /root/update_proxy.sh ───────────────────────────────────
generate_update_script() {
    cat > /root/update_proxy.sh <<'UPDATEEOF'
#!/bin/bash
set -e
source /etc/pursuer.env

REPO="/root/myconf"
if ! ssh-keygen -F github.com -f /root/.ssh/known_hosts >/dev/null 2>&1 \
   && ! ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts >/dev/null 2>&1; then
    echo "[update] [ERROR] 未找到 github.com 的受信任 host key，请先补齐 /root/.ssh/known_hosts"
    exit 1
fi
export GIT_SSH_COMMAND="ssh -i /root/.ssh/xconf_deploy -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/root/.ssh/known_hosts -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts"

echo "[update] 拉取最新配置..."
git -C "$REPO" pull

# ── Hysteria2 ──────────────────────────────────────────────────
if [[ -f "$REPO/hysteria/config.yaml" ]] && [[ -d /etc/hysteria ]]; then
    echo "[update] 更新 Hysteria2 配置..."
    _hys_conf="/etc/hysteria/config.yaml"
    _hys_bak="/etc/hysteria/config.yaml.bak"
    _hys_new="/etc/hysteria/config.yaml.new"

    rm -f "$_hys_new"
    cp "$REPO/hysteria/config.yaml" "$_hys_new"
    sed -i "s|HYS_DOMAIN|${HYS_DOMAIN}|g" "$_hys_new"

    # 备份当前配置
    [[ -f "$_hys_conf" ]] && cp "$_hys_conf" "$_hys_bak"

    if ! mv "$_hys_new" "$_hys_conf"; then
        echo "[update] [ERROR] 配置写入失败，正在恢复..."
        rm -f "$_hys_new"
        [[ -f "$_hys_bak" ]] && mv "$_hys_bak" "$_hys_conf"
        exit 1
    fi

    if ! systemctl restart hysteria-server.service; then
        echo "[update] [ERROR] Hysteria2 启动失败，正在回滚..."
        [[ -f "$_hys_bak" ]] && mv "$_hys_bak" "$_hys_conf"
        systemctl restart hysteria-server.service 2>/dev/null || true
        echo "[update] [ERROR] 已回滚。"
        exit 1
    fi

    # systemctl start 对 Type=simple/exec 服务仅等进程拉起即返回 0；
    # 坏配置会让进程立即退出，需额外验证服务确实存活。
    sleep 2
    if ! systemctl is-active hysteria-server.service &>/dev/null; then
        echo "[update] [ERROR] Hysteria2 启动后立即退出（配置无效），正在回滚..."
        [[ -f "$_hys_bak" ]] && mv "$_hys_bak" "$_hys_conf"
        systemctl restart hysteria-server.service 2>/dev/null || true
        echo "[update] [ERROR] 已回滚。"
        exit 1
    fi

    rm -f "$_hys_new"
    rm -f "$_hys_bak"
    echo "[update] Hysteria2 已更新并重启"
fi

# ── Xray ───────────────────────────────────────────────────────
if [[ -d "$REPO/xray" ]] && [[ -d /usr/local/etc/xray/conf ]]; then
    _xray_jsons=("$REPO/xray/"*.json)
    if [[ ! -f "${_xray_jsons[0]}" ]]; then
        echo "[update] myconf/xray/ 无 JSON 文件，跳过 Xray 更新"
    else
        echo "[update] 更新 Xray 配置（暂存 → 校验 → swap）..."
        _confdir="/usr/local/etc/xray/conf"
        _conf_new="/usr/local/etc/xray/conf.new"
        _conf_bak="/usr/local/etc/xray/conf.bak"
        rm -rf "$_conf_new" && mkdir -p "$_conf_new"
        for f in "${_xray_jsons[@]}"; do
            fname=$(basename "$f")
            cp "$f" "${_conf_new}/${fname}"
            sed -i \
                -e "s|X_DOMAIN|${X_DOMAIN}|g" \
                -e "s|WG_LISTEN_IP|${WG_LISTEN_IP}|g" \
                "${_conf_new}/${fname}"
        done
        if ! xray run --test -confdir "$_conf_new"; then
            rm -rf "$_conf_new"
            echo "[update] [ERROR] 新配置校验失败，线上配置未变动"
            exit 1
        fi
        systemctl stop xray 2>/dev/null || true
        rm -rf "$_conf_bak"
        if ! mv "$_confdir" "$_conf_bak"; then
            echo "[update] [ERROR] 无法备份当前配置目录，恢复 Xray..."
            systemctl start xray 2>/dev/null || true
            rm -rf "$_conf_new"
            exit 1
        fi
        if ! mv "$_conf_new" "$_confdir"; then
            echo "[update] [ERROR] 配置目录 swap 失败，正在回滚..."
            mv "$_conf_bak" "$_confdir" 2>/dev/null || true
            systemctl start xray 2>/dev/null || true
            echo "[update] [ERROR] 已回滚"
            exit 1
        fi
        _xray_ok=false
        if systemctl start xray; then
            sleep 2
            systemctl is-active xray &>/dev/null && _xray_ok=true
        fi
        if [[ "$_xray_ok" != true ]]; then
            echo "[update] [ERROR] Xray 启动失败或启动后立即退出，回滚至上一版配置..."
            rm -rf "/usr/local/etc/xray/conf.failed"
            mv "$_confdir" "/usr/local/etc/xray/conf.failed"
            mv "$_conf_bak" "$_confdir"
            systemctl start xray 2>/dev/null || true
            echo "[update] [ERROR] 已回滚。失败的配置保留于 /usr/local/etc/xray/conf.failed 供排查"
            exit 1
        fi
        rm -rf "$_conf_bak"
        echo "[update] Xray 已更新并重启"
    fi
fi

echo "[update] 代理配置更新完成"
UPDATEEOF
    chmod +x /root/update_proxy.sh
    info "更新脚本已生成 → /root/update_proxy.sh"
}

# ── 安装 TG 通知脚本（下载模板，替换占位符，安装到目标路径）──────
# 用法：install_tg_script <模板URL> <安装路径> [权限，默认755]
# 占位符：读取 VPS_NAME（→DEVICE）、TG_TOKEN、TG_ID 环境变量，缺失则交互
install_tg_script() {
    local src_url="$1"
    local dest="$2"
    local mode="${3:-755}"

    local device="${VPS_NAME:-}"
    local tg_token="${TG_TOKEN:-}"
    local tg_id="${TG_ID:-}"

    if [[ -z "$device" ]]; then
        echo -en "${YELLOW}请输入设备名称（不含 | 等特殊字符）: ${NC}"
        read -r device
    fi
    device="${device//|/}"

    if [[ -z "$tg_token" ]]; then
        echo -en "${YELLOW}请输入 Telegram Bot Token: ${NC}"
        read -r tg_token
    fi
    if [[ -z "$tg_id" ]]; then
        echo -en "${YELLOW}请输入 Telegram Chat ID: ${NC}"
        read -r tg_id
    fi

    [[ -z "$device" || -z "$tg_token" || -z "$tg_id" ]] && {
        error "设备名、TG Token、TG ID 均不能为空"; return 1
    }

    local tmp
    tmp=$(mktemp /tmp/pursuer_XXXXXX.sh)
    echo -e "${CYAN}[↓]${NC} 正在下载 $(basename "$src_url") ..."
    if ! curl -fsSL "$src_url" -o "$tmp"; then
        error "下载失败: $src_url"; rm -f "$tmp"; return 1
    fi

    sed -i \
        -e "s|DEVICE|${device}|g" \
        -e "s|TG_TOKEN|${tg_token}|g" \
        -e "s|TG_ID|${tg_id}|g" \
        "$tmp"

    mv "$tmp" "$dest"
    chmod "$mode" "$dest"
    info "TG 通知脚本已安装 → $dest"
}

# ── 下载并执行远端脚本 ───────────────────────────────────────────
run_remote() {
    local script_name="$1"; shift
    local url="${GITHUB_RAW}/${script_name}"
    local tmp
    tmp=$(mktemp /tmp/pursuer_XXXXXX.sh)

    echo -e "${CYAN}[↓]${NC} 正在下载 ${url} ..."
    if ! curl -fsSL "$url" -o "$tmp"; then
        error "下载失败: $url"
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$tmp"
    bash "$tmp" "$@" || { local rc=$?; rm -f "$tmp"; return "$rc"; }
    rm -f "$tmp"
}
