#!/usr/bin/env bash
# modules/tcp_tune.sh — TCP 自动自检调优（包装器模块）
# 由 pursuer.sh source 后调用 _module_main，不可直接执行
#
# 环境变量（可选，均有合理默认值）：
#   TCP_TUNE_ACTION          apply（默认）| rollback | recommend
#   TCP_TUNE_PROFILE         general（默认）| interactive | throughput
#   TCP_TUNE_ENGINE          auto（默认）| v4 | v5
#   TCP_TUNE_CLIENT_BW_MBPS  客户端带宽（Mbps），空=自动探测
#   TCP_TUNE_CLIENT_RTT_MS   客户端 RTT（ms），空=自动探测
#   TCP_TUNE_VPS_BW_MBPS     VPS 带宽（Mbps），空=自动探测
#   TCP_TUNE_EXTREME         auto（默认）| on | off
#   TCP_TUNE_CC              auto（默认）| bbr3 | bbr2 | bbr | cubic
#   TCP_TUNE_QDISC           auto（默认）| fq | cake

_module_main() {
    title "TCP 自动自检调优"

    local action="${TCP_TUNE_ACTION:-apply}"

    # ── 1. 下载三个文件到同一 tmpdir ─────────────────────────────────
    # tcp-auto-tune.sh 通过 SCRIPT_DIR 定位 AWK 引擎，三文件必须同目录
    local _tmpdir
    _tmpdir=$(mktemp -d /tmp/tcp-tune-XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '${_tmpdir}'" RETURN

    local _main="${_tmpdir}/tcp-auto-tune.sh"
    local _v4="${_tmpdir}/tcp_tune_v4.awk"
    local _v5="${_tmpdir}/tcp_tune_v5.awk"

    info "下载 tcp-auto-tune.sh 及 AWK 引擎..."
    if ! curl -fsSL "${GITHUB_RAW}/lib/tcp-auto-tune.sh" -o "$_main" 2>/dev/null; then
        error "无法下载 lib/tcp-auto-tune.sh"; return 1
    fi
    if ! curl -fsSL "${GITHUB_RAW}/lib/tcp_tune_v4.awk" -o "$_v4" 2>/dev/null; then
        error "无法下载 lib/tcp_tune_v4.awk"; return 1
    fi
    if ! curl -fsSL "${GITHUB_RAW}/lib/tcp_tune_v5.awk" -o "$_v5" 2>/dev/null; then
        error "无法下载 lib/tcp_tune_v5.awk"; return 1
    fi
    chmod +x "$_main"
    info "下载完成 ✓"

    # ── 2. 执行（TCP_TUNE_* 环境变量由调用方 export，自动透传）────────
    case "$action" in
        apply)
            info "执行: tcp-auto-tune apply --diff"
            bash "$_main" apply --diff
            ;;
        rollback)
            info "执行: tcp-auto-tune rollback"
            bash "$_main" rollback
            ;;
        recommend)
            info "执行: tcp-auto-tune recommend --diff"
            bash "$_main" recommend --diff
            ;;
        *)
            error "未知 TCP_TUNE_ACTION: ${action}，可选 apply / rollback / recommend"
            return 1
            ;;
    esac
}
