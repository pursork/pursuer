#!/usr/bin/env bash
# modules/init_system.sh — 系统初始化（basic_ops + NTP）
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

# 下载 basic_ops 并替换占位符后执行
_run_basic_ops() {
    local port="$1"
    local tz="$2"
    local url="${GITHUB_RAW}/basic_ops"
    local tmp
    tmp=$(mktemp /tmp/pursuer_XXXXXX.sh)

    echo -e "${CYAN}[↓]${NC} 正在下载 ${url} ..."
    if ! curl -fsSL "$url" -o "$tmp"; then
        error "下载失败: $url"; rm -f "$tmp"; return 1
    fi

    # 替换占位符（basic_ops 默认值为 22111 / Asia/Shanghai）
    sed -i "s/22111/${port}/g" "$tmp"
    sed -i "s|Asia/Shanghai|${tz}|g" "$tmp"

    chmod +x "$tmp"
    bash "$tmp" || { local rc=$?; rm -f "$tmp"; return "$rc"; }
    rm -f "$tmp"
}

# 安装 Nezha 探针（安装器建立 service unit，再从 myconf 覆盖 config）
_install_nezha() {
    title "安装 Nezha 探针"

    local nz_server="${NZ_SERVER:-}"
    local nz_secret="${NZ_CLIENT_SECRET:-}"
    local nz_uuid="${NZ_UUID:-}"

    if [[ -z "$nz_server" ]]; then
        echo -en "${YELLOW}请输入 Nezha 服务端地址（如 example.com:443）: ${NC}"
        read -r nz_server
    fi
    if [[ -z "$nz_secret" ]]; then
        echo -en "${YELLOW}请输入 Nezha Agent Secret: ${NC}"
        read -r nz_secret
    fi
    [[ -z "$nz_server" || -z "$nz_secret" ]] && {
        error "NZ_SERVER、NZ_CLIENT_SECRET 不能为空"; return 1
    }

    # 判断安装状态：
    #   known_uuid  — /etc/pursuer.env 有有效 UUID（--setup 已跑过）
    #   existing    — UUID 未知但 config 已存在（跳过 --setup 直接重装）
    #   new         — 全新机器，UUID 尚未分配
    local _installed_config="/opt/nezha/agent/config.yml"
    local _install_mode="new"
    if [[ -n "$nz_uuid" && "$nz_uuid" != "PLACEHOLDER" ]]; then
        _install_mode="known_uuid"
    elif [[ -f "$_installed_config" ]]; then
        _install_mode="existing"
        local _existing_uuid
        _existing_uuid=$(grep -E "^\s*uuid:" "$_installed_config" \
            | sed 's/.*uuid:[[:space:]]*//' | tr -d '"'"'"'[:space:]')
        if [[ -n "$_existing_uuid" ]]; then
            nz_uuid="$_existing_uuid"
            warn "未检测到 NZ_UUID（未跑过 --setup），从已安装配置读取 UUID: ${nz_uuid}"
            warn "建议先运行 --setup 以确保 /etc/pursuer.env 与远端 myconf 同步"
        else
            _install_mode="new"
            warn "已有安装但无法读取 UUID，按新机器处理"
        fi
    else
        warn "NZ_UUID 未设置（新机器），将由安装器自动分配 UUID"
    fi

    # 1. 运行官方安装器（建立 service unit 及二进制，并生成初始 config）
    info "运行 Nezha Agent 安装器 ..."
    local _tmp
    _tmp=$(mktemp /tmp/nezha_install_XXXXXX.sh)
    curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o "$_tmp"
    chmod +x "$_tmp"
    NZ_SERVER="$nz_server" NZ_TLS=true NZ_CLIENT_SECRET="$nz_secret" "$_tmp"
    rm -f "$_tmp"

    if [[ "$_install_mode" == "new" ]]; then
        # 全新机器：保留安装器生成的 config，读取并展示 UUID，提示用户更新远端
        systemctl enable nezha-agent.service
        systemctl restart nezha-agent.service
        info "Nezha Agent 已启动（使用安装器默认配置）"

        local _detected_uuid=""
        if [[ -f "$_installed_config" ]]; then
            _detected_uuid=$(grep -E "^\s*uuid:" "$_installed_config" \
                | sed 's/.*uuid:[[:space:]]*//' | tr -d '"'"'"'[:space:]')
        fi

        echo ""
        echo -e "${BOLD}${YELLOW}══════════ 新机器 — 请完善远端配置 ══════════${NC}"
        if [[ -n "$_detected_uuid" ]]; then
            echo -e "  本台 Nezha Agent UUID："
            echo -e "  ${BOLD}${CYAN}${_detected_uuid}${NC}"
            echo ""
            echo -e "  请在远端仓库 myconf/vps/${VPS_ID:-<VPS_ID>}.env 中更新："
            echo -e "  ${BOLD}NZ_UUID=${_detected_uuid}${NC}"
        else
            warn "未能从安装器配置读取 UUID，请手动查看："
            echo -e "  cat ${_installed_config}"
            echo -e "  并将 uuid 值更新到 myconf/vps/${VPS_ID:-<VPS_ID>}.env"
        fi
        echo -e "${BOLD}${YELLOW}══════════════════════════════════════════════${NC}"
        echo ""
        return 0
    fi

    # known_uuid / existing：从 myconf 拉取模板，替换 UUID，覆盖安装器生成的 config
    info "分发 Nezha 配置 ..."
    setup_deploy_key
    clone_or_pull_myconf

    local _config_tpl="/root/myconf/nezha/config.yml"
    [[ ! -f "$_config_tpl" ]] && { error "未找到 myconf/nezha/config.yml"; return 1; }

    systemctl stop nezha-agent.service 2>/dev/null || true
    cp "$_config_tpl" /tmp/nezha_config.yml
    sed -i "s|NZ_UUID|${nz_uuid}|g" /tmp/nezha_config.yml
    mkdir -p /opt/nezha/agent
    mv /tmp/nezha_config.yml "$_installed_config"
    info "配置已写入 $_installed_config"

    # 3. 启动
    systemctl enable nezha-agent.service
    systemctl restart nezha-agent.service
    info "Nezha Agent 已启动"
}

# 验证并输出初始化结果
_verify_init_system() {
    local port="$1"
    local tz="$2"

    echo ""
    echo -e "${BOLD}${CYAN}══════════════ 验证结果 ══════════════${NC}"

    echo -e "\n${BOLD}[ 时间 ]${NC}"
    date -R

    echo -e "\n${BOLD}[ 时区 ]${NC}"
    timedatectl show --property=Timezone --value

    echo -e "\n${BOLD}[ SSH 端口 ]${NC}"
    if ss -tlnp | grep -q ":${port}"; then
        echo -e "${GREEN}✓ 端口 ${port} 正在监听${NC}"
    else
        echo -e "${YELLOW}⚠ 端口 ${port} 暂未监听（SSH 服务可能需要稍等）${NC}"
    fi

    echo -e "\n${BOLD}[ BBR 拥塞控制 ]${NC}"
    lsmod | grep -i bbr || echo -e "${YELLOW}⚠ BBR 模块未检测到${NC}"
    echo "sysctl: $(sysctl -n net.ipv4.tcp_congestion_control)"

    echo -e "\n${BOLD}[ FQ 队列调度 ]${NC}"
    lsmod | grep -i sch_fq || echo -e "${YELLOW}⚠ sch_fq 模块未检测到${NC}"
    echo "sysctl: $(sysctl -n net.core.default_qdisc)"

    echo -e "\n${BOLD}[ NTP 同步状态 ]${NC}"
    chronyc tracking | grep -E "Reference ID|System time|Leap status"

    echo -e "\n${BOLD}[ 自动安全更新 ]${NC}"
    if systemctl is-enabled --quiet unattended-upgrades 2>/dev/null; then
        echo -e "${GREEN}✓ unattended-upgrades 已启用${NC}"
    else
        echo -e "${YELLOW}⚠ unattended-upgrades 未检测到${NC}"
    fi

    echo -e "\n${BOLD}[ Nezha 探针 ]${NC}"
    if systemctl is-active --quiet nezha-agent.service 2>/dev/null; then
        echo -e "${GREEN}✓ nezha-agent 运行中${NC}"
    else
        echo -e "${YELLOW}⚠ nezha-agent 未运行${NC}"
    fi

    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
}

_module_main() {
    title "系统初始化"

    # SSH 端口（优先：env > 交互）
    local port="${NEW_SSH_PORT:-}"
    if [[ -z "$port" ]]; then
        echo -en "${YELLOW}请输入 SSH 端口: ${NC}"
        read -r port
    fi
    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        error "无效端口: $port"; return 1
    fi

    # 时区（优先：env > 交互）
    local tz="${NEW_TIMEZONE:-}"
    if [[ -z "$tz" ]]; then
        echo -en "${YELLOW}请输入时区 [默认 Asia/Shanghai]: ${NC}"
        read -r tz
        tz="${tz:-Asia/Shanghai}"
    fi
    if ! [[ "$tz" =~ ^[A-Za-z0-9_/+-]+$ ]]; then
        error "无效时区格式: $tz"; return 1
    fi

    info "SSH 端口: $port"
    info "时区: $tz"

    # 安装基础包
    info "更新包列表并安装基础工具..."
    apt update -qq
    apt install -y ufw curl wget unzip socat cron unattended-upgrades

    # 启用自动安全更新
    info "启用 unattended-upgrades 自动安全更新..."
    echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
        | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades
    info "自动安全更新已启用"

    # 执行 basic_ops
    info "执行系统加固（SSH端口/BBR/时区）..."
    _run_basic_ops "$port" "$tz"

    # NTP 同步
    info "配置 chrony NTP 时间同步..."
    systemctl stop systemd-timesyncd 2>/dev/null || true
    systemctl disable systemd-timesyncd 2>/dev/null || true
    apt install -y chrony
    systemctl enable --now chrony
    chronyc makestep

    # Nezha 探针
    _install_nezha

    _verify_init_system "$port" "$tz"
}
