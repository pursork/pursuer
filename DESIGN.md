# Pursuer 系统设计文档

> 开发新模块前必读。本文档描述模块间的依赖关系、执行顺序约束、设计规范和扩展原则。

---

## 一、模块执行顺序（硬性约束）

```
--setup
  ↓
--ssh-key          ← 必须在 --init-system 之前
  ↓
--init-system
  ↓  ↘
  │   --tcp-tune   ← 可选，--init-system 之后任意时刻均可运行（无硬性后置约束）
  ↓
--tailscale        ← 必须在 --dante / --xray 之前（写入 WG_LISTEN_IP）
  ↓
--dante            ← 必须在 --tailscale 之后（绑定 tailscale0）
  ↓
--hysteria         ← 必须在 --xray 之前
  ↓
--xray             ← 最后一个基础设施模块
```

### 约束原因

| 顺序约束 | 原因 |
|---------|------|
| **--setup 必须最先** | 所有模块从 `/etc/pursuer.env` 读参数，此文件由 --setup 写入；同时 setup 负责建立 `myconf` 私有仓库访问能力 |
| **--ssh-key 在 --init-system 之前** | --init-system 通过 basic_ops 变更 SSH 端口并禁用密码登录；若公钥未写入就改端口，会锁死机器 |
| **--tailscale 在 --dante / --xray 之前** | --tailscale 运行后将实际分配的 Tailscale 内网 IP 写入 `WG_LISTEN_IP`；--dante 和 --xray 均绑定该 IP，接口不存在则硬失败 |
| **--dante 在 --tailscale 之后** | danted 将 tailscale0 指定为 internal 接口；接口不存在则 danted 启动失败 |
| **--hysteria 在 --xray 之前** | --xray 安装 nginx 并配置 `hys.conf`，其中引用 `/etc/hysteria/cert/${HYS_DOMAIN}.*`；若 --hysteria 未跑，证书文件不存在，`nginx -t` 失败 |
| **--xray 最后** | --xray 安装 nginx、配置所有 nginx vhost（ssl/hys/x.conf）、运行 autossl.sh；其他服务依赖 nginx 提供的伪装站 |

---

## 二、模块依赖图

### 输入依赖（各模块需要什么）

```
模块              /etc/pursuer.env 中必须存在的 KEY
─────────────     ──────────────────────────────────────────────────
--setup           —（自身产生 pursuer.env；需要 DEPLOY_KEY 环境变量，
                  且 github.com host key 已受信任，或提供 MYCONF_KNOWN_HOSTS）
--ssh-key         VPS_NAME, TG_TOKEN, TG_ID
--init-system     NEW_SSH_PORT, NEW_TIMEZONE,
                  NZ_SERVER, NZ_CLIENT_SECRET, NZ_UUID（PLACEHOLDER 合法）
--tailscale       TS_AUTHKEY, VPS_NAME（或 VPS_ID）
--dante           WG_LISTEN_IP（由 --tailscale 写入）
                  DANTE_EXT_IF（可选，未设则自动探测默认路由网卡）
--hysteria        HYS_DOMAIN, CF_TOKEN, CF_ZONE_ID, ACME_EMAIL
--xray            X_DOMAIN, WG_LISTEN_IP, HYS_DOMAIN,
                  CF_TOKEN, CF_ZONE_ID, ACME_EMAIL
--tcp-tune        — （无 pursuer.env 依赖；BBR 建议已由 --init-system 完成；
                  可选传入 TCP_TUNE_PROFILE / TCP_TUNE_ENGINE 等环境变量）
--update-proxy    X_DOMAIN, WG_LISTEN_IP, HYS_DOMAIN
                  （读取 /root/update_proxy.sh，由 --hysteria/--xray 生成）
```

### 文件依赖（各模块需要什么文件已存在）

```
模块              前置文件
─────────────     ──────────────────────────────────────────────────
--ssh-key         —
--init-system     —
--dante           —（tailscale0 接口由 --tailscale 建立，非文件依赖）
--hysteria        /root/.ssh/xconf_deploy（由 --setup 写入）
                  /root/myconf/hysteria/config.yaml
--xray            /root/.ssh/xconf_deploy
                  /root/myconf/xray/*.json
                  /etc/hysteria/cert/${HYS_DOMAIN}.{cer,key}  ← --hysteria 产生
                  /etc/hysteria/web                          ← --hysteria 产生
--tcp-tune        — （仅需 awk、curl、ping、sysctl，均为基础系统包）
--update-proxy    /root/update_proxy.sh  ← --hysteria 或 --xray 产生
```

### 各模块产出（供后续模块使用）

```
模块              产出文件/资源
─────────────     ──────────────────────────────────────────────────
--setup           /etc/pursuer.env（含 common.env 公共字段 + per-VPS 字段）
                  /root/.ssh/xconf_deploy
                  /root/myconf/（git clone）

--tailscale       tailscaled 服务（安装 + 启动）
                  Tailscale 内网连接（hostname = VPS_NAME）
                  /etc/pursuer.env 中 WG_LISTEN_IP = 实际分配的 TS IP

--dante           danted 服务（安装 + 启动）
                  SOCKS5 代理监听 tailscale0:12000（method: none，无认证）
                  /etc/danted.conf
                  /etc/pursuer.env 中 DANTE_EXT_IF = 探测到的出站网卡

--ssh-key         /root/.ssh/authorized_keys
                  /etc/ssh/sshrc（TG 登录告警，HTTPS + 短超时 + best-effort）
                  /etc/cron.weekly/update-pubkey

--init-system     sshd_config（新端口 + 禁密码登录）
                  /opt/nezha/agent/config.yml + nezha-agent.service

--hysteria        /etc/hysteria/cert/${HYS_DOMAIN}.{cer,key}  ← xray 依赖
                  /etc/hysteria/config.yaml
                  /etc/hysteria/web/index.html
                  /root/autossl.sh（hysteria 续期块）
                  /root/update_proxy.sh（hysteria 段）

--xray            /usr/local/share/xray/xray.{crt,key}
                  /usr/local/etc/xray/conf/*.json
                  nginx（安装 + 启动）
                  /etc/nginx/sites-available/ssl.conf
                  /etc/nginx/sites-available/hys.conf  ← 引用 hysteria 证书
                  /etc/nginx/sites-available/x.conf
                  /root/autossl.sh（xray 续期块，并执行一次）
                  /root/xclean.sh（定时清理 xray 日志）
                  /root/update_proxy.sh（完整版，包含 hysteria + xray）

--tcp-tune        /etc/sysctl.d/99-tcp-auto-tune.conf（apply 写入）
                  /var/lib/tcp-auto-tune/last-runtime.conf（apply 写入，rollback 读取）
                  /var/lib/tcp-auto-tune/last-file.conf（apply 写入，rollback 读取）
```

---

## 三、关键子系统说明

### 3.1 nginx 的角色

nginx 是唯一的「公网入口管理者」，由 **--xray** 负责安装和配置。

```
port 80   → ssl.conf  → HTTP 301 重定向到 HTTPS
port 443  → hys.conf  → 伪装成普通 HTTPS 站（Hysteria2 client 不走这里）
port 443  → x.conf    → Xray 伪装站（Reality 直接监听另一端口，nginx 作为 fallback）
```

**推论**：任何需要 nginx 的新模块，必须在 --xray 之后运行，或自行安装 nginx（不推荐，会造成状态分裂）。

### 3.2 证书体系

```
acme.sh（dns_cf 插件）
  ├── HYS_DOMAIN 证书 → /etc/hysteria/cert/     （由 --hysteria 申请）
  │     reloadcmd: systemctl restart hysteria-server && { systemctl reload nginx 2>/dev/null || true; }
  └── X_DOMAIN 证书   → /usr/local/share/xray/  （由 --xray 申请）
        reloadcmd: systemctl reload nginx

续期触发链：
  acme.sh 内置 cron（每日）→ 检测即将到期 → 执行 reloadcmd
  /root/autossl.sh cron（每月 6 日 10:10）→ 手动 --install-cert，作为备份
```

**注意**：--hysteria 不运行 autossl.sh（此时 nginx 未安装）；其 reloadcmd 会忽略 nginx 缺失，但 hysteria 重启失败仍返回非 0。--xray 在步骤 4 安装 nginx 后才运行 autossl.sh，此时两个续期块都已写入，两个 reloadcmd 都能成功。

### 3.3 WG_LISTEN_IP 的角色

`WG_LISTEN_IP` 是 Tailscale 分配的内网 IP（100.x.x.x），由 `--tailscale` 在运行时写入 `/etc/pursuer.env`。`--dante` 将该 IP 所在的 `tailscale0` 指定为 danted 的 `internal` 接口；`--xray` 的 socks5 inbound 绑定该 IP。两者均确保代理入口仅在 Tailscale 内网可达，不暴露于公网。

**推论**：`--tailscale` 必须在 `--dante` / `--xray` 之前完成。两者的前置检查均会验证 `tailscale0` 接口上是否存在 `WG_LISTEN_IP`（含 3 次重试，1s 间隔），不存在则硬失败（`return 1`）。

**禁止**：在 `myconf/vps/<id>.env` 中手动写 `WG_LISTEN_IP`——该字段由 `--tailscale` 覆写，手动值会被覆盖且无意义。

### 3.4 autossl.sh 的幂等写入机制

各模块用 marker 块写入 autossl.sh，互不干扰：

```bash
# --- hysteria-cert-begin ---
...
# --- hysteria-cert-end ---

# --- xray-cert-begin ---
...
# --- xray-cert-end ---
```

写入前先删除同名 marker 块（`sed -i '/begin/,/end/d'`），再追加，保证幂等。新模块如需添加续期逻辑，必须遵循此 marker 格式。

---

## 四、新模块开发规范

### 4.1 模块结构

```bash
#!/usr/bin/env bash
# modules/<name>.sh — 说明
# 由 pursuer.sh source 后调用 _module_main，不可直接执行

_module_main() {
    title "模块标题"

    # 1. 读取参数（env → 交互）
    local foo="${FOO:-}"
    if [[ -z "$foo" ]]; then
        echo -en "${YELLOW}请输入 foo: ${NC}"
        read -r foo
    fi
    [[ -z "$foo" ]] && { error "foo 不能为空"; return 1; }

    # 2. 执行逻辑...
}
```

### 4.2 参数读取规则

- **所有参数优先从 `/etc/pursuer.env` 读取**（pursuer.sh 启动时已 source）
- 仅在 env 中无值时才交互提示
- 模块内对参数做严格非空检查，失败时 `return 1`（不用 `exit`，避免影响调用方 shell）

### 4.3 幂等性设计

| 操作类型 | 幂等实现方式 |
|---------|------------|
| 写入 /etc/pursuer.env | 使用 `write_pursuer_env()`（先删旧行再追加）|
| 安装软件 | 检查二进制/service 是否存在，存在则跳过或直接 reinstall |
| 写入配置文件 | 先删 marker 块再追加（autossl.sh 模式）|
| 配置 sshd_config | 先删旧块再追加（ssh_key 模式）|
| 分发 xray 配置 | 原子 mv swap + rollback |
| crontab 条目 | `grep -qF` 检查存在后再追加 |
| 服务启动后存活校验 | `sleep 2 + systemctl is-active`（`Type=simple` 进程可能立即退出但 start 返回 0）|
| acme.sh 证书 | 捕获 exit 2（已存在），不视为错误 |

### 4.4 首次安装 vs 重装检测

若模块会产生「部署后才能知道的值」（如 NZ_UUID），必须：

1. 检测该值是否已知（env 中非空非 PLACEHOLDER）
2. 若已知 → 直接使用（重装路径）
3. 若未知但产物文件已存在 → 从文件读取，warn 用户先跑 --setup（existing 路径）
4. 若未知且文件不存在 → 全新安装，安装后读取并**醒目展示**生成值，提示更新远端 myconf

参考实现：`modules/init_system.sh` 中的 `_install_nezha()`。

### 4.5 服务停止顺序

```bash
# 正确：先拉配置，必要时先在临时目录完成渲染/校验，再切换 live 文件
clone_or_pull_myconf
cp /root/myconf/<service>/config.yaml /tmp/<service>.new
# sed / 校验 / 下载依赖文件...
systemctl restart <service>
# 若 restart 后立即退出：回滚旧配置

# 错误：先停再拉，网络失败时服务停了但配置没更新
systemctl stop <service>
clone_or_pull_myconf   # 如果失败，服务已停
```

对于 `Type=simple` 服务，`systemctl start/restart` 返回 0 不代表服务已稳定存活。必须补 `sleep 2 && systemctl is-active` 二次校验，失败时进入回滚路径。

### 4.6 myconf Host Key 信任边界

`clone_or_pull_myconf()` 不再使用 `StrictHostKeyChecking=no`。首次拉取私有 `myconf` 前，必须满足以下任一条件：

- `github.com` host key 已存在于 `/root/.ssh/known_hosts` 或 `/etc/ssh/ssh_known_hosts`
- 通过环境变量 `MYCONF_KNOWN_HOSTS` 提供 `known_hosts` 记录，供 `--setup` 写入

原因：`myconf` 内容会被 root 进程用于生成配置和脚本，关闭 host key 校验会把首次连接 MITM 直接扩大为远程配置投毒。

### 4.7 Xray 配置分发（原子 swap 模式）

同文件系统内双 rename，带回滚：

```bash
_confdir="/usr/local/etc/xray/conf"
_conf_new="/usr/local/etc/xray/conf.new"   # 与 conf 同一文件系统
_conf_bak="/usr/local/etc/xray/conf.bak"

# 填充 conf.new → xray run --test 校验 → stop →
# mv conf→conf.bak（rename①）→ mv conf.new→conf（rename②）→ start
# 任意步骤失败 → 回滚到 conf.bak
```

**禁止**：先 `rm -f conf/*` 再 `cp`（中间有窗口）。**禁止**：用 /tmp 暂存（跨文件系统，mv 退化为 cp，不原子）。

### 4.8 TG 通知脚本

使用 `install_tg_script()` 而非自行处理，它负责：
- 从 env 读取 VPS_NAME、TG_TOKEN、TG_ID
- 下载模板，替换 DEVICE/TG_TOKEN/TG_ID 占位符
- 安装到目标路径并设置权限

`secure-ssh` 属于登录钩子，必须坚持“短超时 + best-effort”原则：外部查询失败不能阻塞 SSH 登录链路，也不应依赖明文 HTTP。

### 4.9 DNS A 记录检查

凡需要域名可达（代理服务、证书验证后的实际连接）的模块，参数收集完成后调用：

```bash
check_dns_a "$domain" "$cf_token" "$cf_zone_id"
```

此函数仅 warn，不中断流程（acme.sh dns_cf 不需要 A 记录也能签发证书）。

### 4.10 nginx 依赖

需要 nginx 的新模块不得自行安装 nginx。应：
- 检查 nginx 是否已安装：`command -v nginx`
- 若未安装，`error "请先运行 --xray 以安装并配置 nginx"; return 1`
- 将 nginx vhost 配置放入 `sites-available/`，用 `ln -sf` 启用，`nginx -t && systemctl reload nginx`

`--xray` 还必须在早期检查 Hysteria 产物：
- `/etc/hysteria/cert/${HYS_DOMAIN}.cer`
- `/etc/hysteria/cert/${HYS_DOMAIN}.key`
- `/etc/hysteria/web/`

任一缺失时应直接报错并提示先运行 `--hysteria`，不要等到 `nginx -t` 才失败。

---

## 五、未来模块规划约束

### 其他代理协议模块

- 若需要 nginx：必须在 --xray 之后，且仅做 vhost 追加，不重新安装 nginx
- 若需要 acme 证书：检查 `/root/.acme.sh/acme.sh` 是否存在，不存在则安装
- 若产生 per-VPS 值：遵循 NZ_UUID 三路检测模式

---

## 六、/etc/pursuer.env 字段全览

**来源说明**：`common.env` = `myconf/vps/common.env`；`per-VPS` = `myconf/vps/<id>.env`；`运行时` = 模块运行时写入。

| KEY | 来源 | 消费方 |
|-----|------|-------|
| VPS_ID | --setup（命令行参数）| setup 摘要 |
| VPS_NAME | per-VPS | install_tg_script（→ DEVICE）, --tailscale（hostname）|
| NEW_SSH_PORT | common.env | --init-system（basic_ops） |
| NEW_TIMEZONE | common.env | --init-system（basic_ops） |
| HYS_DOMAIN | per-VPS | --hysteria, --xray（nginx hys.conf） |
| X_DOMAIN | per-VPS | --xray（xray config + nginx x.conf） |
| WG_LISTEN_IP | **运行时（--tailscale 写入）** | --dante（danted internal）, --xray（xray socks5 inbound）, update_proxy.sh |
| DANTE_EXT_IF | **运行时（--dante 写入）** | --dante（danted external，重跑时跳过探测） |
| NZ_UUID | per-VPS / 安装器生成 | --init-system（nezha config） |
| TG_TOKEN | common.env | install_tg_script |
| TG_ID | common.env | install_tg_script |
| CF_TOKEN | common.env | --hysteria, --xray（acme.sh dns_cf） |
| CF_ZONE_ID | common.env | --hysteria, --xray（acme.sh + check_dns_a） |
| ACME_EMAIL | common.env | --hysteria, --xray（acme.sh 注册） |
| NZ_SERVER | common.env | --init-system（nezha agent） |
| NZ_CLIENT_SECRET | common.env | --init-system（nezha agent） |
| TS_AUTHKEY | common.env | --tailscale（tailscale up --authkey） |
