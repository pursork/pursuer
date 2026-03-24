#!/usr/bin/env bash
# modules/tailscale.sh — 安装 Tailscale 并加入内网，写入 WG_LISTEN_IP
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

_module_main() {
    title "Tailscale 内网组网"

    # ── 参数读取 ───────────────────────────────────────────────────
    local ts_authkey="${TS_AUTHKEY:-}"
    local vps_name="${VPS_NAME:-${VPS_ID:-}}"

    [[ -z "$ts_authkey" ]] && { error "TS_AUTHKEY 未配置（应在 myconf/vps/common.env 中设置）"; return 1; }
    [[ -z "$vps_name" ]]   && { error "VPS_NAME / VPS_ID 未配置"; return 1; }

    info "目标 hostname: ${vps_name}"

    # ── 1. 检测当前状态 ────────────────────────────────────────────
    local _installed=false _connected=false _existing_ip=""

    if command -v tailscale &>/dev/null; then
        _installed=true
        if systemctl is-active tailscaled &>/dev/null; then
            _existing_ip=$(tailscale ip -4 2>/dev/null || true)
            [[ -n "$_existing_ip" ]] && _connected=true
        fi
    fi

    if [[ "$_connected" == true ]]; then
        info "检测到 Tailscale 已连接（当前 IP: ${_existing_ip}）"
    elif [[ "$_installed" == true ]]; then
        info "Tailscale 已安装，当前未连接"
    else
        info "Tailscale 未安装，开始全新安装"
    fi

    # ── 2. 安装（仅未安装时）──────────────────────────────────────
    if [[ "$_installed" == false ]]; then
        info "下载并安装 Tailscale..."
        if ! curl -fsSL https://tailscale.com/install.sh | sh; then
            error "Tailscale 安装脚本失败"
            return 1
        fi
        systemctl enable tailscaled
    fi

    # ── 3. 启动 tailscaled（未运行时）─────────────────────────────
    if ! systemctl is-active tailscaled &>/dev/null; then
        info "启动 tailscaled..."
        if ! systemctl start tailscaled; then
            error "tailscaled 启动失败"
            return 1
        fi
        sleep 2   # 等待守护进程就绪
    fi

    # ── 4. 已连接：更新 hostname；未连接：执行 tailscale up ────────
    if [[ "$_connected" == true ]]; then
        local _cur_host
        # tailscale status 首行格式：100.x.x.x  hostname  user@  os  -
        _cur_host=$(tailscale status 2>/dev/null | awk 'NR==1{print $2}' || true)

        if [[ "$_cur_host" == "$vps_name" ]]; then
            info "hostname 已匹配（${vps_name}），无需重新认证"
        else
            info "更新 hostname: ${_cur_host:-unknown} → ${vps_name}"
            # tailscale set 在较新版本可用；旧版回退到 up（不会重置 IP）
            if ! tailscale set --hostname="$vps_name" 2>/dev/null; then
                warn "tailscale set 不可用，尝试 tailscale up 更新 hostname"
                tailscale up --hostname="$vps_name" 2>/dev/null || true
            fi
        fi
    else
        info "加入 Tailscale 网络（authkey: ${ts_authkey:0:20}...）"
        if ! tailscale up --authkey="$ts_authkey" --hostname="$vps_name"; then
            error "tailscale up 失败，请检查："
            error "  1. TS_AUTHKEY 是否有效且为 reusable 类型"
            error "  2. 网络是否可访问 controlplane.tailscale.com（443/udp）"
            tailscale status 2>/dev/null || true
            return 1
        fi
    fi

    # ── 5. 等待 IP 分配（最多 30s，6 × 5s）────────────────────────
    local _ts_ip="" _i
    for _i in 1 2 3 4 5 6; do
        _ts_ip=$(tailscale ip -4 2>/dev/null || true)
        [[ -n "$_ts_ip" ]] && break
        info "等待 Tailscale IP 分配... (${_i}/6)"
        sleep 5
    done

    if [[ -z "$_ts_ip" ]]; then
        error "30s 内未分配到 IP，连接超时"
        error "诊断信息："
        tailscale status 2>/dev/null || true
        return 1
    fi

    # ── 6. 验证服务状态 ────────────────────────────────────────────
    local _state
    _state=$(tailscale status --json 2>/dev/null \
        | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 \
        || echo "unknown")

    if [[ "$_state" == "Running" ]]; then
        info "Tailscale 状态: Running ✓"
    else
        warn "Tailscale 状态: ${_state}（IP 已分配但状态异常，继续写入 env）"
    fi

    # ── 7. 验证本机网卡已有该 IP（供 xray bind 前置检查用）─────────
    local _retries=3 _r
    for _r in $(seq 1 $_retries); do
        ip addr show tailscale0 2>/dev/null | grep -q "$_ts_ip" && break
        sleep 2
    done
    if ! ip addr show tailscale0 2>/dev/null | grep -q "$_ts_ip"; then
        warn "tailscale0 接口上暂未找到 ${_ts_ip}，xray socks5 bind 可能需要等待"
    else
        info "tailscale0 接口确认持有 ${_ts_ip} ✓"
    fi

    # ── 8. 写入 pursuer.env ────────────────────────────────────────
    write_pursuer_env "WG_LISTEN_IP" "$_ts_ip"
    info "WG_LISTEN_IP=${_ts_ip} 已写入 /etc/pursuer.env"

    # ── 9. 摘要 ───────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${CYAN}══════════ Tailscale 状态 ══════════${NC}"
    tailscale status 2>/dev/null || true
    echo -e "${BOLD}${CYAN}════════════════════════════════════${NC}"
    echo ""
    info "完成。后续运行 --xray 时 socks5 将监听在 ${_ts_ip}"
}
