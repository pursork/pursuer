#!/usr/bin/env bash
# modules/update_proxy.sh — 一键更新代理配置（从 myconf 私有仓库分发）
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

_module_main() {
    title "更新代理配置"

    if [[ ! -f /root/update_proxy.sh ]]; then
        error "/root/update_proxy.sh 不存在，请先完成 Hysteria2 或 Xray 的安装"
        return 1
    fi

    info "执行 /root/update_proxy.sh ..."
    bash /root/update_proxy.sh
}
