#!/usr/bin/env bash
# modules/dante.sh — 安装 Dante SOCKS5 代理（监听 tailscale0:12000）
# 依赖：--tailscale 已运行（tailscale0 接口存在且 WG_LISTEN_IP 已写入 /etc/pursuer.env）
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

# ── apt 失败原因分类 ────────────────────────────────────────────────
# 返回 0 = 包不在源里（调用方可 fallback prebuilt）
# 返回 1 = 真实错误（调用方应直接中断）
_apt_fail_category() {
    local _out="$1" _exit="$2"
    if echo "$_out" | grep -qi "Could not get lock\|dpkg was interrupted"; then
        error "apt 被锁（dpkg/apt 正在运行），请等待其他包管理操作完成后重试"
        return 1
    fi
    if echo "$_out" | grep -qi \
        "Temporary failure in name resolution\|Failed to connect\|Connection timed out\|Cannot initiate the connection"; then
        error "apt 失败：DNS/网络不可达，请检查网络连接"
        return 1
    fi
    if echo "$_out" | grep -qi \
        "Hash Sum mismatch\|GPG error\|NO_PUBKEY\|clearsigned file isn't valid\|Release file.*is not valid yet"; then
        error "apt 失败：签名或索引损坏，请检查 apt sources 或运行 apt-get clean"
        return 1
    fi
    if echo "$_out" | grep -qi "Unable to locate package\|No packages found\|Couldn't find package"; then
        return 0  # 包不在源里，允许 fallback
    fi
    error "apt 失败（退出码 ${_exit}）："
    echo "$_out" | tail -8 >&2
    return 1
}

# ── 下载并安装预编译包 ──────────────────────────────────────────────
# 参数：$1 = distro 标识（debian12 | debian13）
_install_dante_prebuilt() {
    local _variant="${1}"
    local _base_url="https://github.com/pursork/dante-server/releases/download/latest-build"
    local _pkg="dante-binary-${_variant}-amd64.tar.gz"
    local _pkg_url="${_base_url}/${_pkg}"
    local _sha_url="${_pkg_url}.sha256"

    info "下载预编译包（${_variant}）：${_pkg}"

    local _tmptar _tmpsha
    _tmptar=$(mktemp /tmp/dante-pkg-XXXXXX.tar.gz)
    _tmpsha=$(mktemp /tmp/dante-sha-XXXXXX.sha256)

    if ! curl -fsSL "${_pkg_url}" -o "${_tmptar}"; then
        error "预编译包下载失败：${_pkg_url}"
        error "请先在 GitHub 触发 workflow：pursork/dante-server → Actions → build-dante"
        rm -f "${_tmptar}" "${_tmpsha}"
        return 1
    fi

    if curl -fsSL "${_sha_url}" -o "${_tmpsha}" 2>/dev/null; then
        local _expected _actual
        _expected=$(awk '{print $1}' "${_tmpsha}")
        _actual=$(sha256sum "${_tmptar}" | awk '{print $1}')
        if [[ "${_expected}" != "${_actual}" ]]; then
            error "SHA256 校验失败（期望 ${_expected}，实际 ${_actual}）"
            rm -f "${_tmptar}" "${_tmpsha}"
            return 1
        fi
        info "SHA256 校验通过 ✓"
    else
        warn "未能获取 .sha256 文件，跳过完整性校验"
    fi

    tar -xzf "${_tmptar}" -C /
    rm -f "${_tmptar}" "${_tmpsha}"
    systemctl daemon-reload
}

# ── Debian 12 安装：apt 优先，仅"包不在源里"时 fallback prebuilt ───
_install_dante_debian12() {
    local _out _exit

    _out=$(apt-get update 2>&1); _exit=$?
    if [[ $_exit -ne 0 ]]; then
        _apt_fail_category "$_out" "$_exit" || return 1
        # update 失败但分类为"包不存在"是异常情况，直接报错
        error "apt-get update 失败（无法确认源状态）"
        return 1
    fi

    _out=$(apt-get install -y dante-server 2>&1); _exit=$?
    if [[ $_exit -eq 0 ]]; then
        info "dante-server 已通过 apt 安装"
        return 0
    fi

    if _apt_fail_category "$_out" "$_exit"; then
        # 仅"包不在源里"时允许 fallback
        warn "Debian 12 apt 源中无 dante-server，回退到预编译包（debian12）..."
        _install_dante_prebuilt "debian12"
        return $?
    else
        return 1
    fi
}

# ── 主逻辑 ─────────────────────────────────────────────────────────
_module_main() {
    title "安装 Dante SOCKS5 代理"

    # ── 1. 前置检查：Tailscale 必须已完成部署 ─────────────────────
    local wg_ip="${WG_LISTEN_IP:-}"
    if [[ -z "$wg_ip" ]]; then
        error "WG_LISTEN_IP 未配置，请先运行 --tailscale"
        return 1
    fi

    local _wg_found=false _r
    for _r in 1 2 3; do
        ip addr show tailscale0 2>/dev/null | grep -q "${wg_ip}" && { _wg_found=true; break; }
        sleep 1
    done
    if [[ "$_wg_found" != true ]]; then
        error "tailscale0 接口上未找到 ${wg_ip}（已重试 3 次）"
        error "请先运行 --tailscale，确保 Tailscale 已连接"
        return 1
    fi
    info "tailscale0 接口确认持有 ${wg_ip} ✓"

    # ── 2. 确定出站网卡（env → 自动探测）─────────────────────────
    local ext_if="${DANTE_EXT_IF:-}"
    if [[ -z "$ext_if" ]]; then
        ext_if=$(ip route get 8.8.8.8 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
    fi
    if [[ -z "$ext_if" ]]; then
        error "无法自动探测出站网卡，请设置 DANTE_EXT_IF=<网卡名> 后重试"
        return 1
    fi
    if ! ip link show "$ext_if" &>/dev/null; then
        error "网卡 ${ext_if} 不存在（DANTE_EXT_IF=${ext_if}），请手动指定正确网卡"
        return 1
    fi
    info "出站网卡: ${ext_if}"
    info "SOCKS5 监听: ${wg_ip}:12000（tailscale0）"

    # ── 3. 检测 OS 版本，分支安装 ────────────────────────────────
    local _os_id _os_ver
    _os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
    _os_ver=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-}")

    if [[ "$_os_id" != "debian" ]]; then
        error "不支持的操作系统：${_os_id}（仅支持 Debian）"
        return 1
    fi
    info "系统：Debian ${_os_ver}"

    local dante_bin=""
    if command -v danted &>/dev/null; then
        dante_bin="$(command -v danted)"
        info "Dante 已安装（danted）：${dante_bin}"
    elif command -v sockd &>/dev/null; then
        dante_bin="$(command -v sockd)"
        info "Dante 已安装（sockd）：${dante_bin}"
    elif [[ "$_os_ver" == "12" ]]; then
        # Debian 12：apt 优先，仅"包不在源里"时 fallback debian12 prebuilt
        _install_dante_debian12 || return 1
        dante_bin="$(command -v danted 2>/dev/null || command -v sockd 2>/dev/null || true)"
    elif [[ "$_os_ver" == "13" ]]; then
        # Debian 13：apt 无此包，直接走 debian13 prebuilt
        info "Debian 13：apt 无 dante-server 包，直接下载预编译包..."
        _install_dante_prebuilt "debian13" || return 1
        dante_bin="$(command -v sockd 2>/dev/null || command -v danted 2>/dev/null || true)"
    else
        error "不支持的 Debian 版本：${_os_ver}（支持：12、13）"
        return 1
    fi

    if [[ -z "${dante_bin}" ]]; then
        error "Dante 安装后仍未找到 danted/sockd 可执行文件"
        return 1
    fi

    # ── 4. 兜底：确保 systemd 能识别 danted.service ──────────────
    # 不依赖路径检查（/lib vs /usr/lib 在不同发行版不同），
    # 直接问 systemctl —— 若识别不到就写 /etc/systemd/system/danted.service
    if ! systemctl cat danted.service &>/dev/null; then
        info "systemd 未识别 danted.service，写入 /etc/systemd/system/danted.service ..."
        printf '%s\n' \
            '[Unit]' \
            'Description=SOCKS (v4 and v5) proxy daemon (Dante)' \
            'Documentation=man:sockd(8)' \
            'After=network-online.target tailscaled.service' \
            'Wants=network-online.target' \
            '' \
            '[Service]' \
            'Type=simple' \
            "ExecStart=${dante_bin} -f /etc/danted.conf" \
            'ExecReload=/bin/kill -HUP $MAINPID' \
            'Restart=on-failure' \
            'RestartSec=2' \
            '' \
            '[Install]' \
            'WantedBy=multi-user.target' \
            > /etc/systemd/system/danted.service
        systemctl daemon-reload
    fi

    # ── 5. 写入 /etc/danted.conf ──────────────────────────────────
    info "写入 /etc/danted.conf..."
    [[ -f /etc/danted.conf ]] && cp /etc/danted.conf /etc/danted.conf.bak

    cat > /etc/danted.conf <<EOF
logoutput: stderr

internal: tailscale0 port = 12000
external: ${ext_if}

# socksmethod/clientmethod 兼容 dante 1.4.2（Debian 12 apt）和 1.4.4（prebuilt）
# 旧版 method: none 仅控制 SOCKS 协商阶段，不覆盖 client 握手阶段
socksmethod: none
clientmethod: none
user.notprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
}
EOF

    # ── 6. 启用并重启服务 ──────────────────────────────────────────
    systemctl enable danted
    systemctl restart danted

    sleep 2
    if ! systemctl is-active danted &>/dev/null; then
        error "danted 启动失败，回滚配置..."
        if [[ -f /etc/danted.conf.bak ]]; then
            cp /etc/danted.conf.bak /etc/danted.conf
            systemctl restart danted 2>/dev/null || true
            warn "已回滚至备份配置"
        fi
        error "诊断：journalctl -u danted -n 50"
        return 1
    fi

    # ── 7. 验证端口监听 ────────────────────────────────────────────
    if ss -tlnp 2>/dev/null | grep -q ":12000" || \
       ss -ulnp 2>/dev/null | grep -q ":12000"; then
        info "端口 12000 监听确认 ✓"
    else
        warn "ss 未检测到 :12000，可能还在初始化（不影响后续部署）"
    fi

    # ── 8. 持久化出站网卡 ──────────────────────────────────────────
    write_pursuer_env "DANTE_EXT_IF" "$ext_if"
    info "DANTE_EXT_IF=${ext_if} 已写入 /etc/pursuer.env"

    # ── 9. 摘要 ───────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${CYAN}══════════════ Dante 部署完成 ══════════════${NC}"
    echo -e "  SOCKS5 监听: ${wg_ip}:12000  (tailscale0)"
    echo -e "  出站网卡:    ${ext_if}"
    echo -e "  认证方式:    无（仅 Tailscale 内网可达，安全边界由 TS 保证）"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════${NC}"
    echo ""
    systemctl status danted --no-pager -l
}
