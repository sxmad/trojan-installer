# trojan-installer

[简体中文](README.md) | [English](README.en.md)

面向 Google Cloud x86_64 Debian/Ubuntu VM 的 Trojan-GFW 安装器，生成 Shadowrocket 可导入的链接和二维码。默认使用 **TCP 443**，可指定 **TCP 8443**；证书签发和续期统一使用 **HTTP-01 / TCP 80**。

安装器修订号：`2026-10-18.1`。

## 安装

将 `trojan.example.com` 的 A 记录指向 VM 的静态公网 IPv4，填写自己的域名和邮箱：

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh \
  -o /root/trojan-install.sh
bash /root/trojan-install.sh install \
  --domain trojan.example.com --email you@example.com
```

使用 8443：

```bash
bash /root/trojan-install.sh install \
  --domain trojan.example.com --email you@example.com --port 8443
```

安装器会安装依赖，校验固定版本的官方二进制，申请证书，创建 systemd 服务，并通过本机 HTTPS 和 SOCKS5 出站检查后输出连接信息。脚本不修改云端或主机防火墙，也不重启 VM。

## GCP 与同机 HY2

| 用途 | 需要放行的入站端口 |
|---|---|
| 默认 Trojan | TCP 443 |
| `--port 8443` 的 Trojan | TCP 8443 |
| 两种安装方式的证书签发、每天检查及到期续期 | TCP 80 |
| 已有 HY2 | 保持原有规则，例如 UDP 443 和其 HTTPS/证书使用的 TCP 443 |

GCP VPC 防火墙规则必须匹配 VM 的 VPC、网络标记或服务账号；主机上的 UFW/firewalld 也需要允许相应端口。TCP 80 必须能被公网 ACME 验证服务访问，不能只允许自己的客户端 IP。无需开放 UDP 8443，也不要开放仅监听回环地址的回落端口 18080。

如果已有 `sxmad/hysteria2-installer` 使用 TCP/UDP 443，选择 Trojan `--port 8443`，并开放 TCP 80；两者的监听及证书验证端口就可以分开。建议 Trojan 使用独立域名，例如 `trojan.example.com`。此脚本不会停止或修改 HY2。

HTTP-01 的公网验证端口固定为 80，不能随 Trojan 改成 8443。TCP 80 如果已有 Web 服务占用，本脚本会停止安装并说明原因；当前版本不提供 webroot 或 DNS-01 集成。换端口本身不保证更快或更稳定。

前提：

- 使用 x86_64 Debian 12/13 或 Ubuntu LTS、运行 systemd，VM 可访问软件源、GitHub release、ACME 和 Google。
- A 记录直连 VM；不要开启 Cloudflare 橙云代理。当前安装器只监听 IPv4，需移除 AAAA 记录。
- 使用静态外部 IPv4。地区和机器规格应按客户端运营商、晚高峰丢包与实际并发测试选择，不能单凭 TW/HK/JP/US 的距离判断速度。

## 参数

| 参数 | 行为 |
|---|---|
| `--domain DOMAIN` | 无默认值；缺少时询问。 |
| `--email EMAIL` | 无默认值；缺少时询问 ACME 邮箱。 |
| `--port PORT` | 默认 443；支持 1–65535，但保留 80 给 HTTP-01、18080 给本地回落。配置、URI、二维码和自测同步使用此端口。 |
| `--no-bbr` | 跳过 BBR 配置，保留已有系统设置；不是强制关闭已启用的 BBR。 |
| `--password-stdin` | 从标准输入读取 12–128 位密码，允许字母、数字、`.`、`_`、`-`；否则生成 16 位随机十六进制密码。 |
| `--version v1.16.0` | 只接受仓库固定的官方核心版本。 |
| `--no-page` | 不生成 `asdfq` 首页，仍保留本地回落服务和代理自测。 |
| `--yes` / `-y` | 跳过覆盖已有安装的确认。 |
| `--keep-credentials` | 卸载时保留 URI、二维码和配置备份。 |
| `--help` | 显示用法。 |

使用 `--password-stdin` 时，缺少的域名和邮箱从 `/dev/tty` 读取，不会消耗密码管道；没有交互终端则停止。

## BBR：默认尝试启用，可以跳过

Trojan 的外层连接使用 TCP。安装器默认尝试加载系统已有的 `tcp_bbr` 模块，启用 `fq + bbr`，并写入独立的 `/etc/sysctl.d/99-trojan-installer-bbr.conf`。不会下载安装新内核或第三方调优脚本，不需要重启。内核不支持时继续安装；应用失败会尝试恢复原来的设置。非本安装器管理的同名配置不会被覆盖。

BBR 可能改善高延迟或有丢包线路的吞吐与排队延迟，实际收益取决于线路；它不能修复断网、IP 阻断、证书失效，也没有固定的倍数提速。它是系统 TCP 设置，会影响其他新建 TCP 连接；不等于 HY2 的 QUIC BBR，也不代表 BBRv3。修改默认 qdisc 不会替换已经运行的网卡队列。

保留系统原设置：在安装命令末尾加 `--no-bbr`。查看生效值及实际 TCP 连接：

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
ss -tin
```

## 证书续期与稳定性

`trojan-cert-renew.timer` 每天检查，剩余有效期不足 30 天时使用 `lego --http renew --days 30` 续期。续期不停止或重启 Trojan，而是在校验证书有效期、域名及密钥匹配后部署证书，通过 `SIGUSR1` 热加载。已有会话保留原 SSL 上下文，新连接使用新证书。

ACME 失败或新证书无效时保留已部署的证书。证书下载成功但复制或热加载失败时，下次检查会继续部署；不会仅因缓存证书已经续期而漏掉部署。原本停止的 Trojan 保持停止。日志可用于发现持续失败，不能把自动重试视为永久不断线保证。

```bash
systemctl list-timers trojan-cert-renew.timer
journalctl -u trojan-cert-renew.service --no-pager
# 手动进行同样的检查（未到期且部署正常时不会申请新证书）
systemctl start trojan-cert-renew.service
```

重新安装或更新核心仍会重启服务，已有连接可能中断；无中断行为指正常定时续期。

## Shadowrocket 与自测

成功后输出 `trojan://密码@域名:端口?peer=域名&allowInsecure=0#trojan`、终端二维码及 `/root/trojan-域名.{txt,png}`（权限 600）。核对类型 Trojan、端口 443 或 8443、Peer/SNI 为域名，并保持证书校验开启。

输出前检查配置、systemd 主进程的实际监听端口、本机 HTTPS 回落页以及经临时 Trojan 客户端访问 Google `generate_204` 的 HTTP 204。回落页仅监听于 `127.0.0.1:18080`，由 Trojan 对外提供 TLS。应用 UDP 可经 Trojan 协议转发，客户端到服务器的外层仍为 TCP/TLS。

本机测试通过不能证明客户端到 GCP 的公网线路畅通；仍须用 Shadowrocket 实际连接，并在常用网络和晚高峰观察 YouTube 播放、重连及持续传输。

## 管理与旧版本迁移

```bash
bash /root/trojan-install.sh status
bash /root/trojan-install.sh restart
bash /root/trojan-install.sh update
```

`update` 备份并替换固定版本核心，保留现有配置、密码和端口；运行中的服务会重启，原先停止的保持停止。**它不会更新已安装的续期脚本，也不代表升级到新核心版本。**

从旧 TLS-ALPN-01 安装迁移此修复时，先开放 TCP 80，再重新下载新脚本执行 `install`（按需加 `--port 8443`）。重装会备份现有配置，默认生成新密码和二维码；需要沿用密码时使用 `--password-stdin`。证书仍有效时会复用本地 lego 证书，之后由新 HTTP-01 续期任务管理。安装失败会尝试恢复原配置和服务。

## 排错

| 现象 | 检查 |
|---|---|
| ACME 超时或拒绝连接 | A/AAAA、CAA、TCP 80、公网防火墙目标、域名是否经过代理、80 是否被其他服务占用。 |
| Trojan 监听端口冲突 | `ss -ltnp`；可选 `--port 8443`，脚本不会替你关闭其他程序。 |
| 服务 active 但手机无网 | TCP 443/8443、防火墙规则目标、密码、Peer/SNI、证书校验与 Shadowrocket 路由；换客户端网络验证。 |
| HTTPS 页面可打开但代理失败 | 页面只证明 TLS 回落可用，还要检查认证及代理配置。 |
| 续期失败 | 查看续期 journal，修复 TCP 80/DNS；避免反复强制申请触发 CA 速率限制。 |
| BBR 未生效 | `sysctl net.ipv4.tcp_available_congestion_control` 与 `sysctl net.ipv4.tcp_congestion_control`；不支持时保留系统默认。 |

```bash
journalctl -b -u trojan.service --since '10 minutes ago' --no-pager
ss -H -ltnp 'sport = :8443'
```

日志可能包含客户端地址或认证信息，分享前请脱敏。

## 卸载

```bash
bash /root/trojan-install.sh uninstall
```

删除本安装器的服务、配置、证书、lego 数据、静态页及所创建的用户；删除所创建的 BBR 配置并尝试恢复安装前的 TCP 设置。默认还删除生成的 URI、二维码和安装器备份，可用 `--keep-credentials` 保留。依赖包、DNS、GCP/主机防火墙及其他服务不受管理。立即卸载重装可能触发证书申请速率限制。

## 核心维护限制

此修复保留原仓库固定的 **Trojan-GFW v1.16.0** 官方二进制及 SHA256。该 release 发布于 2020 年，二进制报告 **OpenSSL 1.1.1g**。校验哈希只能验证下载一致性，不能说明旧依赖仍获维护；更新系统 OpenSSL 不能假定会更新此预编译二进制内的依赖。此 PR 修复安装器功能，不将核心替换为其他实现，也不作完整安全审计结论。

## 可复现验证

```bash
bash tests/test_installer.sh
TROJAN_BIN=/path/to/trojan TEST_SERVER_PORT=8443 bash tests/test_local_proxy.sh
```

第一组不接触主机服务或 sysctl，覆盖端口、URI、BBR 跳过/加载/失败恢复，以及真实证书下的续期成功、错误域名、错误密钥、复制失败、热加载失败重试和停止状态。第二组用真实 Trojan 二进制和本地 CA 验证生成配置、8443 TLS、SOCKS 转发、新证书生效、换证前的连接仍可收发以及换证后的新连接。

这些测试不替代真实 VM 上的 systemd、GCP 防火墙、ACME 公网签发和 Shadowrocket 实机验证；也不测量跨境线路性能。

参考：[Trojan 配置](https://trojan-gfw.github.io/trojan/config.html) · [SIGUSR1 热加载](https://trojan-gfw.github.io/trojan/usage.html) · [HTTP-01](https://letsencrypt.org/docs/challenge-types/#http-01-challenge) · [Google BBR](https://github.com/google/bbr) · [lego](https://go-acme.github.io/lego/)

## License

MIT
