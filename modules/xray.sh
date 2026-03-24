#!/usr/bin/env bash
# modules/xray.sh — 安装 Xray（VLESS + REALITY + socks5@WG）
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

_module_main() {
    title "安装 Xray (VLESS + REALITY)"

    # Reality 域名：env 或交互
    local x_domain="${X_DOMAIN:-}"
    if [[ -z "$x_domain" ]]; then
        echo -en "${YELLOW}请输入 Reality 域名（如 pr.example.com）: ${NC}"
        read -r x_domain
    fi
    [[ -z "$x_domain" ]] && { error "域名不能为空"; return 1; }

    # WG/Headscale 接口 IP：env 或交互
    local wg_ip="${WG_LISTEN_IP:-}"
    if [[ -z "$wg_ip" ]]; then
        echo -en "${YELLOW}请输入 WireGuard/Headscale 接口 IP（socks5 监听）: ${NC}"
        read -r wg_ip
    fi
    [[ -z "$wg_ip" ]] && { error "WG IP 不能为空"; return 1; }

    # Hysteria2 域名（nginx hys.conf 用）：env 或交互
    local hys_domain="${HYS_DOMAIN:-}"
    if [[ -z "$hys_domain" ]]; then
        echo -en "${YELLOW}请输入 Hysteria2 域名（nginx 配置用）: ${NC}"
        read -r hys_domain
    fi
    [[ -z "$hys_domain" ]] && { error "Hysteria2 域名不能为空"; return 1; }

    # CF 凭证：env 或交互
    local cf_token="${CF_TOKEN:-}"
    local cf_zone_id="${CF_ZONE_ID:-}"
    if [[ -z "$cf_token" ]]; then
        echo -en "${YELLOW}请输入 Cloudflare API Token: ${NC}"
        read -r cf_token
    fi
    if [[ -z "$cf_zone_id" ]]; then
        echo -en "${YELLOW}请输入 Cloudflare Zone ID: ${NC}"
        read -r cf_zone_id
    fi
    [[ -z "$cf_token" || -z "$cf_zone_id" ]] && { error "CF Token 和 Zone ID 不能为空"; return 1; }

    # acme.sh 注册邮箱：env 或交互
    local acme_email="${ACME_EMAIL:-}"
    if [[ -z "$acme_email" ]]; then
        echo -en "${YELLOW}请输入 acme.sh 注册邮箱: ${NC}"
        read -r acme_email
    fi
    [[ -z "$acme_email" ]] && { error "邮箱不能为空"; return 1; }

    # 派生路径变量
    local path_hys_cer="/etc/hysteria/cert/${hys_domain}.cer"
    local path_hys_key="/etc/hysteria/cert/${hys_domain}.key"
    local path_hys_web="/etc/hysteria/web"
    local x_ssl_cert="/usr/local/share/xray/xray.crt"
    local x_ssl_key="/usr/local/share/xray/xray.key"
    local x_nginx_server=".${x_domain}"

    info "Reality 域名: $x_domain"
    info "WG 接口 IP: $wg_ip"
    info "Hysteria2 域名: $hys_domain"
    check_dns_a "$x_domain" "$cf_token" "$cf_zone_id"

    # 预检：WG_LISTEN_IP 必须已存在于本机接口（由 --tailscale 写入并绑定）
    # tailscale 内部短暂刷新路由时 ip addr 可能瞬态缺失，重试 3 次（间隔 1s）再失败
    local _wg_found=false _r
    for _r in 1 2 3; do
        ip addr show tailscale0 2>/dev/null | grep -q "${wg_ip}" && { _wg_found=true; break; }
        sleep 1
    done
    if [[ "$_wg_found" != true ]]; then
        error "WG_LISTEN_IP ${wg_ip} 未在 tailscale0 接口上找到（已重试 3 次）。"
        error "请先运行 --tailscale，确保 Tailscale 已连接且 IP 已写入 /etc/pursuer.env。"
        return 1
    fi

    # 预检：依赖 Hysteria 证书和伪装目录，避免 Xray 已切换而 Nginx 最后失败
    local _missing_hys_dep=false
    if [[ ! -f "$path_hys_cer" ]]; then
        error "未找到 Hysteria 证书：${path_hys_cer}"
        _missing_hys_dep=true
    fi
    if [[ ! -f "$path_hys_key" ]]; then
        error "未找到 Hysteria 私钥：${path_hys_key}"
        _missing_hys_dep=true
    fi
    if [[ ! -d "$path_hys_web" ]]; then
        error "未找到 Hysteria 伪装站目录：${path_hys_web}"
        _missing_hys_dep=true
    fi
    if [[ "$_missing_hys_dep" == true ]]; then
        error "请先运行 --hysteria，确认 Hysteria 证书和伪装站目录已就绪。"
        return 1
    fi

    # 1. Deploy Key
    setup_deploy_key

    # 2. 安装 Xray
    info "安装 Xray ..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    mkdir -p /var/log/xray

    # 3. 确保 xray service 使用 confdir 模式（幂等）
    # 优先检查安装器生成的 drop-in，若不存在则自行创建，确保 systemd 与测试行为一致
    local _dropin_dir="/etc/systemd/system/xray.service.d"
    local _dropin_installer="${_dropin_dir}/10-donot_touch_single_conf.conf"
    local _dropin_pursuer="${_dropin_dir}/10-pursuer-confdir.conf"
    local _xray_confdir="/usr/local/etc/xray/conf"

    if grep -q "confdir" "$_dropin_installer" 2>/dev/null || \
       grep -q "confdir" "$_dropin_pursuer"   2>/dev/null; then
        info "xray service 已使用 confdir 模式，跳过修改"
    elif [[ -f "$_dropin_installer" ]]; then
        cp "$_dropin_installer" /tmp/xray.service.raw.bak
        sed -i \
            "s#-config /usr/local/etc/xray/config.json#-confdir ${_xray_confdir}#" \
            "$_dropin_installer"
        info "xray service drop-in 已更新为 confdir 模式"
    else
        # 安装器未生成 drop-in，手动创建（防止 systemd 仍按 config.json 启动）
        mkdir -p "$_dropin_dir"
        cat > "$_dropin_pursuer" <<EOF
[Service]
ExecStart=
ExecStart=/usr/local/bin/xray run -confdir ${_xray_confdir}
EOF
        info "已创建 confdir 模式 drop-in → ${_dropin_pursuer}"
    fi

    # 4. 安装 Nginx
    apt install -y nginx

    # 5. 安装 acme.sh（如不存在）
    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        info "安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | sh -s "email=${acme_email}"
        /root/.acme.sh/acme.sh --upgrade --auto-upgrade
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    else
        info "acme.sh 已存在，跳过安装"
    fi

    # 6. 申请证书（exit 2 = 已存在，跳过）
    info "申请证书：$x_domain ..."
    local _rc=0
    CF_Token="$cf_token" CF_Zone_ID="$cf_zone_id" \
        /root/.acme.sh/acme.sh --issue -d "$x_domain" --dns dns_cf || _rc=$?
    if [[ $_rc -eq 2 ]]; then
        warn "证书已存在且未到期，跳过申请"
    elif [[ $_rc -ne 0 ]]; then
        error "证书申请失败（exit: $_rc）"; return 1
    fi

    mkdir -p /usr/local/share/xray
    /root/.acme.sh/acme.sh --install-cert -d "$x_domain" \
        --key-file   "$x_ssl_key" \
        --fullchain-file "$x_ssl_cert"
    chmod +r "$x_ssl_cert" "$x_ssl_key"

    # 7. 持久化变量
    write_pursuer_env "X_DOMAIN" "$x_domain"
    write_pursuer_env "WG_LISTEN_IP" "$wg_ip"
    info "X_DOMAIN / WG_LISTEN_IP 已写入 /etc/pursuer.env"

    # 8. 分发 Xray 配置（原子 swap：conf.new → conf，可回滚）
    clone_or_pull_myconf
    local _json_files=(/root/myconf/xray/*.json)
    if [[ ! -f "${_json_files[0]}" ]]; then
        error "myconf/xray/ 中未找到 JSON 配置文件"; return 1
    fi

    # stage 放在与 confdir 同一文件系统，保证 mv 是 rename() 原子操作
    local _confdir="/usr/local/etc/xray/conf"
    local _conf_new="/usr/local/etc/xray/conf.new"
    local _conf_bak="/usr/local/etc/xray/conf.bak"
    rm -rf "$_conf_new" && mkdir -p "$_conf_new"

    for f in "${_json_files[@]}"; do
        fname=$(basename "$f")
        cp "$f" "${_conf_new}/${fname}"
        sed -i \
            -e "s|X_DOMAIN|${x_domain}|g" \
            -e "s|WG_LISTEN_IP|${wg_ip}|g" \
            "${_conf_new}/${fname}"
    done

    # 测试暂存配置，失败则服务继续以当前配置运行
    info "校验新配置..."
    if ! xray run --test -confdir "$_conf_new"; then
        rm -rf "$_conf_new"
        error "新配置校验失败，线上配置未变动"; return 1
    fi

    # 测试通过：原子双 rename swap
    mkdir -p "$_confdir"
    systemctl stop xray 2>/dev/null || true
    rm -rf "$_conf_bak"
    if ! mv "$_confdir" "$_conf_bak"; then
        error "无法备份当前配置目录，恢复 Xray..."
        systemctl start xray 2>/dev/null || true
        rm -rf "$_conf_new"
        return 1
    fi
    if ! mv "$_conf_new" "$_confdir"; then
        error "配置目录 swap 失败，正在回滚..."
        mv "$_conf_bak" "$_confdir" 2>/dev/null || true
        systemctl start xray 2>/dev/null || true
        error "已回滚"
        return 1
    fi
    info "Xray 配置已分发"

    # 9. 写入 autossl.sh xray 续期块（幂等，不影响 hysteria 块）
    [[ ! -f /root/autossl.sh ]] && { printf '#!/bin/bash\n' > /root/autossl.sh; chmod +x /root/autossl.sh; }
    info "更新 autossl.sh xray 续期块 ..."
    sed -i '/^# --- xray-cert-begin ---/,/^# --- xray-cert-end ---/d' /root/autossl.sh
    cat >> /root/autossl.sh <<EOF
# --- xray-cert-begin ---
/root/.acme.sh/acme.sh --install-cert -d ${x_domain} \\
    --key-file   ${x_ssl_key} \\
    --fullchain-file ${x_ssl_cert} \\
    --reloadcmd "systemctl reload nginx"
# --- xray-cert-end ---
EOF

    if grep -qF "autossl.sh" /etc/crontab 2>/dev/null; then
        warn "crontab 中已存在 autossl.sh 任务，跳过"
    else
        echo "10 10 6 * * root /bin/bash /root/autossl.sh > /dev/null 2>&1" >> /etc/crontab
        info "已添加续期任务：每月6日 10:10 执行"
    fi
    bash /root/autossl.sh

    # 10. 启动 xray；若失败则回滚至备份配置
    # systemctl restart 对 Type=simple/exec 服务仅等进程拉起即返回 0；
    # 端口被占用等原因会让进程立即退出，需 sleep + is-active 二次存活校验。
    systemctl daemon-reload
    systemctl enable xray
    local _xray_ok=false
    if systemctl restart xray; then
        sleep 2
        systemctl is-active xray &>/dev/null && _xray_ok=true
    fi
    if [[ "$_xray_ok" != true ]]; then
        error "Xray 启动失败，回滚至上一版配置..."
        rm -rf "/usr/local/etc/xray/conf.failed"
        mv "$_confdir" "/usr/local/etc/xray/conf.failed"
        mv "$_conf_bak" "$_confdir"
        systemctl restart xray 2>/dev/null || true
        error "已回滚。失败的配置保留于 /usr/local/etc/xray/conf.failed 供排查"
        return 1
    fi
    rm -rf "$_conf_bak"

    # 11. Nginx 配置
    info "配置 Nginx ..."

    # ssl.conf（通配 SNI 入口）
    wget -q "${GITHUB_RAW}/nginx1" -O /etc/nginx/sites-available/ssl.conf
    sed -i "s#X_NGINX_SERVER#${x_nginx_server}#" /etc/nginx/sites-available/ssl.conf
    ln -sf /etc/nginx/sites-available/ssl.conf /etc/nginx/sites-enabled/ssl.conf

    # hys.conf（Hysteria2 反代）
    wget -q "${GITHUB_RAW}/nginx2" -O /etc/nginx/sites-available/hys.conf
    sed -i \
        -e "s#N_SERVER_443#${hys_domain}#" \
        -e "s#PATH_TO_HYS_CER#${path_hys_cer}#" \
        -e "s#PATH_TO_HYS_KEY#${path_hys_key}#" \
        -e "s#PATH_TO_HYS_WEB#${path_hys_web}#" \
        /etc/nginx/sites-available/hys.conf
    ln -sf /etc/nginx/sites-available/hys.conf /etc/nginx/sites-enabled/hys.conf

    # x.conf（Xray 伪装）
    wget -q "${GITHUB_RAW}/nginx2" -O /etc/nginx/sites-available/x.conf
    sed -i \
        -e "s#N_SERVER_443#${x_domain}#" \
        -e "s#PATH_TO_HYS_CER#${x_ssl_cert}#" \
        -e "s#PATH_TO_HYS_KEY#${x_ssl_key}#" \
        -e "s#PATH_TO_HYS_WEB#${path_hys_web}#" \
        /etc/nginx/sites-available/x.conf
    ln -sf /etc/nginx/sites-available/x.conf /etc/nginx/sites-enabled/x.conf

    rm -f /etc/nginx/sites-enabled/default
    nginx -t
    systemctl restart nginx

    # 12. x-clean 日志清理 cron
    info "配置 x-clean 定时日志清理 ..."
    install_tg_script "${GITHUB_RAW}/x-clean" "/root/xclean.sh" "755"

    if grep -qF "xclean.sh" /etc/crontab 2>/dev/null; then
        warn "crontab 中已存在 xclean.sh 任务，跳过"
    else
        echo "22 8 * * 6 root /bin/bash /root/xclean.sh > /dev/null 2>&1" >> /etc/crontab
        info "已添加日志清理任务：每周六 08:22 执行"
    fi
    systemctl reload cron 2>/dev/null || systemctl restart cron 2>/dev/null || true

    # 13. 生成 update_proxy.sh
    generate_update_script

    echo ""
    echo -e "${BOLD}${CYAN}══════════════ 部署完成 ══════════════${NC}"
    echo -e "  Reality 域名: ${x_domain}"
    echo -e "  WG 接口 IP:   ${wg_ip}"
    echo -e "  客户端配置存于 myconf 私有仓库"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo ""
    systemctl status xray --no-pager -l
    systemctl status nginx --no-pager -l
}
