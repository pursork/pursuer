#!/usr/bin/env bash
# modules/setup.sh — VPS 初始化配置（从 myconf 私有仓库读取 per-VPS 配置）
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

_module_main() {
    title "VPS 初始化配置"

    # VPS_ID：env 或交互
    local vps_id="${VPS_ID:-}"
    if [[ -z "$vps_id" ]]; then
        echo -en "${YELLOW}请输入 VPS ID（对应 myconf/vps/<ID>.env，如 sg01）: ${NC}"
        read -r vps_id
    fi
    [[ -z "$vps_id" ]] && { error "VPS ID 不能为空"; return 1; }

    # 1. 写入 Deploy Key
    setup_deploy_key

    # 2. 确保 git 已安装（裸机可能缺失）
    if ! command -v git &>/dev/null; then
        info "git 未安装，正在安装..."
        apt-get install -y git
    fi

    # 3. 克隆或更新 myconf
    clone_or_pull_myconf

    # 4. 检查 VPS 配置文件
    local vps_env_file="/root/myconf/vps/${vps_id}.env"
    local common_env_file="/root/myconf/vps/common.env"
    if [[ ! -f "$vps_env_file" ]]; then
        error "未找到配置文件：${vps_env_file}"
        error "请在 myconf 仓库中创建 vps/${vps_id}.env"
        return 1
    fi

    # 5. 重建 pursuer.env（先清空，防止历史残留键 e.g. 旧 WG_LISTEN_IP 污染新设计）
    > /etc/pursuer.env
    local key val
    _load_env_file() {
        local _file="$1" _label="$2"
        [[ ! -f "$_file" ]] && return 0
        info "加载 ${_label}..."
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            key="${line%%=*}"; val="${line#*=}"
            if [[ -z "$key" || "$key" == "$line" ]]; then
                warn "跳过无效行: $line"; continue
            fi
            write_pursuer_env "$key" "$val"
        done < "$_file"
    }
    _load_env_file "$common_env_file" "vps/common.env"
    _load_env_file "$vps_env_file"    "vps/${vps_id}.env"

    # 确保 VPS_ID 自身也写入
    write_pursuer_env "VPS_ID" "$vps_id"

    # 6. 输出摘要（屏蔽敏感值）
    echo ""
    echo -e "${BOLD}${CYAN}══════════════ VPS 配置摘要 ══════════════${NC}"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        key="${line%%=*}"
        if [[ "$key" =~ ^(TG_TOKEN|TG_ID|CF_TOKEN|CF_ZONE_ID|ACME_EMAIL|NZ_CLIENT_SECRET|TS_AUTHKEY)$ ]]; then
            echo -e "  ${key}=${YELLOW}****${NC}"
        else
            echo "  ${line}"
        fi
    done < /etc/pursuer.env
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
    echo ""
    info "完成。后续模块直接运行，无需再次输入域名/Token 等参数。"

    # 如果 NZ_UUID 仍为占位符，提醒用户
    local _nz_uuid
    _nz_uuid=$(grep "^NZ_UUID=" /etc/pursuer.env | cut -d= -f2)
    if [[ "$_nz_uuid" == "PLACEHOLDER" ]]; then
        warn "NZ_UUID=PLACEHOLDER：运行 --init-system 后终端会打印真实 UUID，请更新远端 vps/${vps_id}.env"
    fi
}
