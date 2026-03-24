#!/usr/bin/env bash
# modules/hysteria.sh — 安装 Hysteria2 代理
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

_module_main() {
    title "安装 Hysteria2 代理"

    # 域名：env 或交互
    local hys_domain="${HYS_DOMAIN:-}"
    if [[ -z "$hys_domain" ]]; then
        echo -en "${YELLOW}请输入 Hysteria2 域名（如 hs.example.com）: ${NC}"
        read -r hys_domain
    fi
    [[ -z "$hys_domain" ]] && { error "域名不能为空"; return 1; }

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

    info "域名: $hys_domain"
    check_dns_a "$hys_domain" "$cf_token" "$cf_zone_id"

    # 1. Deploy Key
    setup_deploy_key

    # 2. 安装 acme.sh
    if [[ ! -f /root/.acme.sh/acme.sh ]]; then
        info "安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | sh -s "email=${acme_email}"
        /root/.acme.sh/acme.sh --upgrade --auto-upgrade
        /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    else
        info "acme.sh 已存在，跳过安装"
    fi

    # 3. 申请证书（exit 2 = 已存在，跳过）
    info "申请证书：$hys_domain ..."
    local _rc=0
    CF_Token="$cf_token" CF_Zone_ID="$cf_zone_id" \
        /root/.acme.sh/acme.sh --issue -d "$hys_domain" --dns dns_cf || _rc=$?
    if [[ $_rc -eq 2 ]]; then
        warn "证书已存在且未到期，跳过申请"
    elif [[ $_rc -ne 0 ]]; then
        error "证书申请失败（exit: $_rc）"; return 1
    fi

    # 4. 安装 Hysteria2
    info "安装 / 更新 Hysteria2 ..."
    bash <(curl -fsSL https://get.hy2.sh/)

    # 5. 安装证书
    mkdir -p /etc/hysteria/web/ /etc/hysteria/cert/
    /root/.acme.sh/acme.sh --install-cert -d "$hys_domain" \
        --key-file   "/etc/hysteria/cert/${hys_domain}.key" \
        --fullchain-file "/etc/hysteria/cert/${hys_domain}.cer"
    chmod +r "/etc/hysteria/cert/${hys_domain}.cer" \
             "/etc/hysteria/cert/${hys_domain}.key"

    # 6. 持久化域名
    write_pursuer_env "HYS_DOMAIN" "$hys_domain"
    info "HYS_DOMAIN 已写入 /etc/pursuer.env"

    # 7. 分发 Hysteria2 配置（先暂存，最终 restart 失败时回滚）
    local _tmp_conf _tmp_web _conf_bak _web_bak
    _tmp_conf="$(mktemp /tmp/hys_config_XXXXXX.yaml)"
    _tmp_web="$(mktemp /tmp/hys_web_XXXXXX.html)"
    _conf_bak="$(mktemp /tmp/hys_config_bak_XXXXXX.yaml)"
    _web_bak="$(mktemp /tmp/hys_web_bak_XXXXXX.html)"

    clone_or_pull_myconf
    [[ -f /root/myconf/hysteria/config.yaml ]] || { error "myconf/hysteria/config.yaml 不存在"; rm -f "$_tmp_conf" "$_tmp_web" "$_conf_bak" "$_web_bak"; return 1; }
    cp /root/myconf/hysteria/config.yaml "$_tmp_conf"
    sed -i "s|HYS_DOMAIN|${hys_domain}|g" "$_tmp_conf"

    # 8. 下载伪装页面
    info "下载伪装页面 ..."
    wget -q "${GITHUB_RAW}/404.html" -O "$_tmp_web"
    sed -i "s|HYS_DOMAIN|${hys_domain}|g" "$_tmp_web"
    chmod +r "$_tmp_web"

    [[ -f /etc/hysteria/config.yaml ]] && cp /etc/hysteria/config.yaml "$_conf_bak"
    [[ -f /etc/hysteria/web/index.html ]] && cp /etc/hysteria/web/index.html "$_web_bak"

    mv "$_tmp_conf" /etc/hysteria/config.yaml
    mv "$_tmp_web" /etc/hysteria/web/index.html
    info "Hysteria2 配置已分发"

    # 9. 写入 autossl.sh hysteria 续期块（幂等）
    info "更新 autossl.sh hysteria 续期块 ..."
    [[ ! -f /root/autossl.sh ]] && { printf '#!/bin/bash\n' > /root/autossl.sh; chmod +x /root/autossl.sh; }
    sed -i '/^# --- hysteria-cert-begin ---/,/^# --- hysteria-cert-end ---/d' /root/autossl.sh
    cat >> /root/autossl.sh <<EOF
# --- hysteria-cert-begin ---
/root/.acme.sh/acme.sh --install-cert -d ${hys_domain} \\
    --key-file   /etc/hysteria/cert/${hys_domain}.key \\
    --fullchain-file /etc/hysteria/cert/${hys_domain}.cer \\
    --reloadcmd "systemctl restart hysteria-server && { systemctl reload nginx 2>/dev/null || true; }"
# --- hysteria-cert-end ---
EOF

    if grep -qF "autossl.sh" /etc/crontab 2>/dev/null; then
        warn "crontab 中已存在 autossl.sh 任务，跳过"
    else
        echo "10 10 6 * * root /bin/bash /root/autossl.sh > /dev/null 2>&1" >> /etc/crontab
        info "已添加续期任务：每月6日 10:10 执行"
    fi

    # 10. 生成 update_proxy.sh
    generate_update_script

    # 11. 启动服务
    systemctl enable hysteria-server.service
    # --install-cert 注册 reloadcmd 时会立即执行一次；nginx 此时可能未安装，
    # 故 reload nginx 用 && { ... || true; } 隔离：hysteria 失败仍传播错误码，
    # nginx 失败则吞掉（非致命）；后续 acme 内置 cron 续期时同样执行此 reloadcmd
    /root/.acme.sh/acme.sh --install-cert -d "${hys_domain}" \
        --key-file   "/etc/hysteria/cert/${hys_domain}.key" \
        --fullchain-file "/etc/hysteria/cert/${hys_domain}.cer" \
        --reloadcmd "systemctl restart hysteria-server && { systemctl reload nginx 2>/dev/null || true; }"
    systemctl restart hysteria-server.service
    sleep 2
    if ! systemctl is-active hysteria-server.service &>/dev/null; then
        [[ -s "$_conf_bak" ]] && cp "$_conf_bak" /etc/hysteria/config.yaml
        [[ -s "$_web_bak" ]] && cp "$_web_bak" /etc/hysteria/web/index.html
        systemctl restart hysteria-server.service 2>/dev/null || true
        rm -f "$_conf_bak" "$_web_bak"
        error "hysteria-server 启动后立即退出，请检查配置："
        error "  journalctl -u hysteria-server -n 30"
        return 1
    fi
    rm -f "$_conf_bak" "$_web_bak"

    echo ""
    systemctl status hysteria-server.service --no-pager -l
}
