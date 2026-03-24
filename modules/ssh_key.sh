#!/usr/bin/env bash
# modules/ssh_key.sh — 配置 SSH 密钥登录 + Telegram 告警
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

# 追加公钥（去重），失败仅 warn 不中断
_append_pubkeys() {
    local src_url="$1" src_name="$2" auth_keys="$3"
    local content
    content=$(curl -fsSL "$src_url") || { warn "${src_name} 公钥拉取失败，跳过"; return 0; }
    if [[ -z "$content" ]]; then
        warn "${src_name} 公钥内容为空，跳过"; return 0
    fi
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$auth_keys" 2>/dev/null || { echo "$line" >> "$auth_keys"; (( count++ )) || true; }
    done <<< "$content"
    info "${src_name} 公钥已追加（新增 ${count} 条）"
}

# 配置 SSH 登录 Telegram 告警
_setup_ssh_alert() {
    title "配置 SSH 登录 Telegram 告警"
    install_tg_script "${GITHUB_RAW}/secure-ssh" "/etc/ssh/sshrc" "755"
    info "下次 SSH 登录时将发送 Telegram 通知（每次连接仅触发一次）"
}

_module_main() {
    title "配置 SSH 密钥登录"
    local sshd_config="/etc/ssh/sshd_config"
    local auth_keys="/root/.ssh/authorized_keys"
    local backup="${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

    cp "$sshd_config" "$backup"
    info "已备份 → $backup"

    trap 'error "发生错误，正在还原备份..."; cp "$backup" "$sshd_config"; systemctl restart ssh 2>/dev/null || true' ERR

    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    # 主源：sshid.io（必须成功）
    local key_content
    key_content=$(curl -fsSL "$SSH_PUBKEY_URL") || { error "sshid.io 公钥拉取失败"; return 1; }
    [[ -z "$key_content" ]] && { error "sshid.io 公钥内容为空"; return 1; }
    local count=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        grep -qxF "$line" "$auth_keys" 2>/dev/null || { echo "$line" >> "$auth_keys"; (( count++ )) || true; }
    done <<< "$key_content"
    info "sshid.io 公钥已追加（新增 ${count} 条）"

    # 备用源：GitHub（失败不中断）
    _append_pubkeys "$GITHUB_PUBKEY_URL" "GitHub" "$auth_keys"

    chown -R root:root /root/.ssh
    chmod 600 "$auth_keys"
    info ".ssh 权限已设置"

    # 修改 sshd_config（幂等）
    # 1. 删除上次追加的块
    sed -i '/^# === 由 pursuer\.sh 追加 ===/,/^KbdInteractiveAuthentication /d' "$sshd_config"
    # 2. 注释掉原文件中散落的同名指令
    for directive in PermitRootLogin PasswordAuthentication PubkeyAuthentication \
                     ChallengeResponseAuthentication KbdInteractiveAuthentication; do
        sed -i -E "s/^([[:space:]]*${directive}[[:space:]]+.*)$/# \1/" "$sshd_config"
    done
    # 3. 追加新配置块
    cat >> "$sshd_config" <<'EOF'

# === 由 pursuer.sh 追加 ===
PermitRootLogin yes
PasswordAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
EOF
    info "SSH 配置已追加"

    sshd -t || { error "语法校验失败，还原备份"; cp "$backup" "$sshd_config"; return 1; }
    info "语法校验通过"
    systemctl restart ssh
    info "SSH 服务已重启"

    trap - ERR

    # 公钥每周自动同步（双源）
    cat > /etc/cron.weekly/update-pubkey <<'CRONEOF'
#!/bin/bash
AUTH_KEYS="/root/.ssh/authorized_keys"
_sync() {
  local url="$1"
  curl -fsSL "$url" 2>/dev/null | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qxF "$line" "$AUTH_KEYS" 2>/dev/null || echo "$line" >> "$AUTH_KEYS"
  done
}
_sync "https://sshid.io/pursuer"
_sync "https://github.com/pursork.keys"
CRONEOF
    chmod +x /etc/cron.weekly/update-pubkey
    info "公钥每周自动同步任务已更新（sshid.io + GitHub 双源）"

    _setup_ssh_alert
}
