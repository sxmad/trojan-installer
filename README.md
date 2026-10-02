# trojan-installer

[简体中文](README.md) | [English](README.en.md)

面向 Google Cloud VM 的纯净 Trojan-GFW 安装器。它使用官方 **Trojan-GFW v1.16.0**、TCP/TLS 443、Debian/Ubuntu 官方仓库的 `lego` ACME 客户端，以及 Shadowrocket 可导入的 `trojan://` 链接和二维码。域名和邮箱没有默认值；一次命令完成依赖、证书、服务、自测和连接信息。

[一键安装](#一键安装) · [安装前准备](#安装前准备) · [参数](#安装参数) · [管理](#服务管理与更新) · [卸载](#卸载与重新测试) · [排错](#常见问题)

## 设计选择

- 核心固定为官方 Trojan-GFW v1.16.0。旧的 Trojan-Go 和来源不明的一键脚本不会被安装。
- Trojan-GFW 是 TCP/TLS 协议，只需要 **TCP 443**；不需要 Hysteria2 的 UDP 443。
- 证书使用 `lego` 的 **TLS-ALPN-01**。申请时 `lego` 临时占用 TCP 443，申请完成后由 Trojan 接管，因此不需要 Nginx、Certbot 或公网 TCP 80。
- Trojan 的 HTTPS 回落连接到仅监听 `127.0.0.1:18080` 的 Python 静态服务，页面内容为 `asdfq`。Python 服务不直接暴露公网。
- 如果内核提供 BBR，安装器会写入独立的 `/etc/sysctl.d/99-trojan-installer-bbr.conf` 并尝试启用 `fq + bbr`；内核不支持时只提示并继续，不安装第三方调优脚本。

## 推荐 Google Cloud VM

不超过 15 人、速度优先时，建议 Debian 13、`e2-standard-2`（2 vCPU / 8 GB）、30 GB `pd-balanced`、Premium Tier 和静态外部 IPv4。经常多人同时 4K 或下载时升级到 `e2-standard-4`（4 vCPU / 16 GB）。磁盘只保存系统、证书和日志，不保存代理流量。

## 一键安装

安装器修订号：`2026-10-02.2`。必须填写自己的域名和邮箱：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) \
  install --domain trojan.example.com --email you@example.com
```

脚本会安装 `lego`、`qrencode` 等依赖，下载并校验固定版本的官方 Trojan，申请证书，生成最小权限 systemd 服务，启用自动续期，并在本机 HTTPS 回落页和 Trojan SOCKS5 出站自测都通过后才输出密码、URI 和二维码。

## 安装前准备

1. 将域名 A 记录指向 VM 的静态公网 IPv4。不要保留指向别处的旧 AAAA 记录；脚本发现 AAAA 时会停止，以免 ACME 走错误的 IPv6。不要使用 Cloudflare 橙云代理。
2. Google Cloud VPC 防火墙只需放行 **TCP 443**，目标必须匹配此 VM 的 VPC、网络标记或服务账号，源地址范围应覆盖客户端和 Let’s Encrypt。
3. 使用官方 Debian 12/13 或 Ubuntu LTS 镜像，并确保 VM 可以访问 Debian 软件源、GitHub release 和 ACME 服务。

安装器不会修改 Google Cloud 防火墙、关闭 UFW/firewalld、安装 Nginx、上传账号凭据或重启 VM。证书申请期间 Trojan 会短暂停止几秒，让 `lego` 使用 TCP 443 完成挑战。

## 安装参数

| 参数 | 行为 |
|---|---|
| `--domain DOMAIN` | 无默认值；缺少时从终端询问。 |
| `--email EMAIL` | 无默认值；缺少时从终端询问 ACME 邮箱。 |
| `--password-stdin` | 从标准输入读取 12–128 位密码，只允许字母、数字、`.`、`_`、`-`；不指定则生成 16 位十六进制密码。 |
| `--version v1.16.0` | 仅允许当前固定的官方版本；省略时仍使用 v1.16.0。 |
| `--no-page` | 不写入 `asdfq` 首页，但仍保留本地 HTTPS 回落服务和代理自测。 |
| `--yes` / `-y` | 跳过覆盖已有安装的确认；不会跳过证书错误或自测。 |
| `--help` | 显示用法和修订号。 |

缺少域名或邮箱时，普通模式从当前终端询问；和 `--password-stdin` 一起使用时，身份信息只从 `/dev/tty` 读取，不会消耗密码管道。没有交互终端则停止。

## 输出和自测

安装成功后会输出：

- Shadowrocket URI：`trojan://密码@域名:443?peer=域名&allowInsecure=0#trojan`；`peer` 是 TLS SNI；
- Web SSH 终端 Unicode 二维码；
- `/root/trojan-域名.png` 和 `/root/trojan-域名.txt`，权限均为 `600`。

输出前会检查：

1. `trojan -t -c /etc/trojan/server.json` 配置语法；
2. `trojan.service` 为 active 且当前进程监听 TCP 443；
3. `https://域名/` 返回本机 `asdfq` 页面；
4. 临时官方 Trojan 客户端通过 SOCKS5 访问 Google `generate_204`，返回 HTTP 204。

任一步失败都不会输出新的 URI 或二维码。网页成功只证明 TLS 回落可用，手机仍需在 Shadowrocket 中实际连接验证。

证书失败会显示 `lego` 日志，并给出最多三次“1. 修复并重试 / 2. 中断”。域名、DNS、CAA、443 防火墙或 CA 速率限制必须在外部修复；脚本不会猜测或修改云端规则。速率限制会直接停止，避免重复申请。

## 服务管理与更新

```bash
systemctl --no-pager --full status trojan.service
systemctl is-enabled trojan.service
systemctl is-active trojan.service
systemctl list-timers trojan-cert-renew.timer
```

自动续期由 `trojan-cert-renew.timer` 每天检查。需要续期时，它会停止 Trojan、让 `lego` 临时监听 TCP 443、同步新证书再启动 Trojan；失败时会尝试恢复服务，并把日志写入 journal。

更新固定官方程序并保留现有配置和密码：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) update
```

`update` 会备份配置并检查新二进制、配置和 TCP 443；原先停止的服务保持停止，不会重新生成二维码。

## 卸载与重新测试

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) uninstall
```

确认后会停止并删除 Trojan、回落服务、续期 timer、配置、证书副本、静态页、lego 账户/证书数据，以及本安装器创建的 `trojan` 用户和 BBR 配置。安装前已有的 Trojan 用户、二进制和其他文件不会删除；`/root/trojan-域名.{txt,png}`、配置备份、依赖包、DNS 和 Google Cloud 防火墙规则会保留。

卸载后立即重装会重新申请 ACME 证书，可能触发 CA 速率限制。要验证首次依赖安装和证书流程，优先使用新 VM；不需要重启 VM。

## Shadowrocket 首次连接

扫码或导入 URI 后确认：类型 Trojan、地址为域名、端口 `443`、密码为本次新生成的密码、Peer/SNI 为域名、证书校验开启。首次测试可临时使用全局代理路由，再恢复自己的分流规则。Trojan 连接不需要 UDP 443。

## 常见问题

| 现象 | 检查 |
|---|---|
| `lego` challenge timeout / connection refused | A 记录、旧 AAAA、TCP 443 入站、防火墙目标和域名代理；确认没有其他进程占用 443。 |
| TCP 443 已占用 | `ss -ltnp` 查看进程；脚本不会停止或覆盖其他服务。 |
| 服务 active 但手机无网 | 检查 TCP 443、二维码是否为本次密码、Peer/SNI、Shadowrocket 路由，并换网络测试。 |
| 能打开 HTTPS 页面但代理不通 | 页面只验证 TLS 回落；检查密码、URI 和客户端配置。 |
| `apt-get` 显示 `Get`、`Hit`、`Reading package lists... Done` | 只是依赖日志，继续等待证书、自测和二维码。 |
| `Unsupported Config Type` | Trojan 配置必须是 `.json` 文件；这不是协议过旧。 |
| BBR 未启用 | 查看 `cat /proc/sys/net/ipv4/tcp_available_congestion_control`；不支持时脚本会保留系统默认 TCP。 |

查看状态和日志时，日志可能包含客户端地址或认证相关字段，分享前请脱敏：

```bash
journalctl -b -u trojan.service --since '10 minutes ago' --no-pager
journalctl -b -u trojan-cert-renew.service --no-pager
ss -H -ltnp 'sport = :443'
```

## 安全与审计

- 脚本固定官方 Trojan-GFW v1.16.0 下载地址和 release tarball SHA256，下载失败或校验失败不会安装。
- 配置为 `root:trojan`、`0640`；私钥副本为 `root:trojan`、`0640`；服务以 `trojan` 用户运行，只授予绑定 443 所需的能力。
- 不执行第三方 `curl | bash`，不下载公开客户端压缩包，不关闭主机防火墙，不安装外部 BBR 脚本。
- Trojan 只提供 TCP/TLS 代理；速度主要取决于 Google Cloud 地区、运营商线路和 TCP 丢包。

## 验证范围

仓库提供可复现的本地测试：`tests/test_installer.sh` 检查语法、帮助、域名规范化、密码生成和输入拒绝；`tests/test_local_proxy.sh` 使用真实 Trojan-GFW 二进制检查配置、TLS 回落、认证和 SOCKS5 转发。运行后者时可设置 `TROJAN_BIN=/path/to/trojan tests/test_local_proxy.sh`。安装脚本本身还固定 release SHA256、运行 `trojan -t` 并检查生成的 systemd 服务和监听端口。正式部署仍需在真实 Google Cloud VM 上完成 TLS-ALPN 签发和 Shadowrocket 连接验证。

参考资料：

- [Trojan-GFW 官方配置](https://trojan-gfw.github.io/trojan/config.html)
- [Trojan-GFW 官方 Releases](https://github.com/trojan-gfw/trojan/releases)
- [lego 官方文档](https://go-acme.github.io/lego/)
- [Let's Encrypt TLS-ALPN-01](https://letsencrypt.org/docs/challenge-types/#tls-alpn-01)

## License

MIT
