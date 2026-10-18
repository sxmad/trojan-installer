# trojan-installer

[简体中文](README.zh-CN.md) | [English](README.md)

面向 Google Cloud x86_64 Debian/Ubuntu VM 的 Trojan-GFW 安装器，生成 Shadowrocket 可导入的链接和二维码。默认使用 **TCP 443**，可指定 **TCP 8443**；证书签发和续期统一使用 **HTTP-01 / TCP 80**。

安装器修订号：`2026-10-18.4`。

## 安装

先将 `trojan.example.com` 的 A 记录指向 VM 的静态公网 IPv4，填写自己的域名和邮箱。以下命令获取 `main` 分支的安装器；`--version` 选择的是 Trojan 核心版本，与安装器版本不同。

### 一键安装

与 HY2 一样，一条命令完成下载和安装。普通用户通过 `sudo` 运行，无需先执行 `sudo -i`。下面使用 **8443**，执行前放行 **TCP 80 和 TCP 8443**，并确保端口未被其他服务占用：

```bash
sudo bash -c 'bash <(curl -fsSL --proto "=https" --tlsv1.2 \
  https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) install \
  --domain trojan.example.com \
  --email you@example.com \
  --port 8443'
```

每个参数单独一行，修改域名、邮箱和端口即可。续行反斜杠 `\` 必须是该行最后一个字符，后面不能有空格或注释；请保留首尾配对的单引号。

省略 `--port 8443` 即使用默认 **443**，对应放行 TCP 80 和 TCP 443。默认尝试启用系统 BBR；需要跳过时，在末尾单引号之前追加 `--no-bbr`。安装成功后直接输出 Shadowrocket 链接和二维码。

`--tlsv1.2` 指定下载连接的最低 TLS 版本，仍允许协商 TLS 1.3；它不控制 Trojan 或 Shadowrocket 的 TLS 版本。

### 下载后安装

也可以先保存脚本，方便检查内容和后续管理：

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh \
  -o /root/trojan-install.sh
bash /root/trojan-install.sh install \
  --domain trojan.example.com \
  --email you@example.com
```

使用 8443：

```bash
bash /root/trojan-install.sh install \
  --domain trojan.example.com \
  --email you@example.com \
  --port 8443
```

安装器会安装依赖，选择官方稳定版并校验二进制 SHA256，申请证书，创建 systemd 服务，并通过本机 HTTPS 和 SOCKS5 出站检查后输出连接信息。脚本不修改云端或主机防火墙，也不重启 VM。

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
| `--version VERSION` | 默认 `latest`，查询官方最新稳定版；也可指定 `vX.Y.Z`，例如 `v1.16.0`。不接受预发布版。 |
| `--no-page` | 不生成 `asdfq` 首页，仍保留本地回落服务和代理自测。 |
| `--yes` / `-y` | 跳过覆盖已有安装的确认。 |
| `--keep-credentials` | 卸载时保留 URI、二维码和配置备份。 |
| `--help` | 显示用法。 |

使用 `--password-stdin` 时，缺少的域名和邮箱从 `/dev/tty` 读取，不会消耗密码管道；没有交互终端则停止。

### 核心版本与下载校验

截至 2026-10-18，Trojan-GFW 官方最新稳定版仍为 **v1.16.0（2020-06-10 发布）**。`latest` 表示查询该项目的官方稳定版，不会切换为 Xray、sing-box 或其他 Trojan 实现，也不会在后台自动更新核心。

- 默认通过 GitHub Releases API 查询稳定版。API 不可达或限流时停止，并提示重试；不会静默改装其他版本。
- 显式指定 `--version v1.16.0` 可跳过元数据查询，但下载仍需要访问 GitHub。
- v1.16.0 使用安装器内置的已核实 SHA256；其他稳定版必须提供预期命名的 Linux amd64 资产及 GitHub 的 SHA256 digest。缺少哈希或校验失败即停止，不会执行未校验的二进制。

## BBR：默认尝试启用，可以跳过

Trojan 的外层连接使用 TCP。安装器默认尝试加载系统已有的 `tcp_bbr` 模块，启用 `fq + bbr`，并写入独立的 `/etc/sysctl.d/99-trojan-installer-bbr.conf`。不会下载安装新内核或第三方调优脚本，不需要重启。内核不支持时继续安装；应用失败会尝试恢复原来的设置。非本安装器管理的同名配置不会被覆盖。

BBR 可能改善高延迟或有丢包线路的吞吐与排队延迟，实际收益取决于线路；它不能修复断网、IP 阻断、证书失效，也没有固定的倍数提速。它是系统 TCP 设置，会影响其他新建 TCP 连接；不等于 HY2 的 QUIC BBR，也不代表 BBRv3。修改默认 qdisc 不会替换已经运行的网卡队列。

保留系统原设置：在安装参数末尾加 `--no-bbr`；使用上方一键命令时，该参数须放在末尾单引号之前。查看生效值及实际 TCP 连接：

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

以下命令使用“下载后安装”方式保存的 `/root/trojan-install.sh`。如果使用一键安装，先按上方下载命令保存脚本，再执行管理操作。

```bash
bash /root/trojan-install.sh status
bash /root/trojan-install.sh restart
bash /root/trojan-install.sh update
```

`update` 默认查询最新稳定版，再备份并替换核心，保留现有配置、密码和端口；运行中的服务会重启，原先停止的保持停止。也可执行 `bash /root/trojan-install.sh update --version v1.16.0` 指定版本。**它不会更新安装器本身或已安装的续期脚本；若上游没有新发布，核心版本不会提高。**

从旧 TLS-ALPN-01 安装迁移此修复时，先开放 TCP 80，再重新下载新脚本执行 `install`（按需加 `--port 8443`）。重装会备份现有配置，默认生成新密码和二维码；需要沿用密码时使用 `--password-stdin`。证书仍有效时会复用本地 lego 证书，之后由新 HTTP-01 续期任务管理。安装失败会尝试恢复原配置和服务。

## 长期运行与内存

**默认不建议每天或每周定时重启。** 安装脚本完成后会退出，长期运行的是 Trojan 和本机 HTTP 回落服务。重启正常代理会断开现有连接，也不能修复内存泄漏。每天的证书定时器只热加载证书，不重启 Trojan。

两个服务均配置 `Restart=on-failure`、`RestartSec=2s`。systemd 可在进程异常退出后尝试恢复，但受宿主机启动频率限制影响；它不能发现“进程仍在、服务已卡住”，也不能保证整机内存耗尽时恢复成功。手动 `systemctl stop` 不会触发自动重启。

这次安装器检查没有发现所有服务器都必须定时重启的依据，也**不代表已证明核心没有内存泄漏**。上游 [v1.16.0 内存问题报告](https://github.com/trojan-gfw/trojan/issues/625)涉及路由器 NAT/客户端模式和 P2P 流量，不能直接认定你的 VM 服务端存在同一问题。旧核心及其内置依赖仍有维护风险，详见本页“核心维护限制”。

建议在 24–72 小时内，分别记录相近负载和空闲后的数据。繁忙后 RSS 较高，本身不等于泄漏；相近负载下反复增长、可用内存下降或出现 OOM 才需要进一步排查。以下命令只读取状态：

```bash
date -Is
systemctl show trojan.service \
  -p ActiveState -p SubState -p MainPID -p NRestarts \
  -p MemoryCurrent -p TasksCurrent -p Restart -p RestartUSec
proxy_pid=$(systemctl show trojan.service -p MainPID --value)
if [[ "$proxy_pid" =~ ^[1-9][0-9]*$ ]]; then
  ps -p "$proxy_pid" -o pid,etime,rss,%mem,%cpu,comm
fi
free -h
journalctl -k -b --since '24 hours ago' \
  --grep 'Out of memory|oom-kill|Killed process' --no-pager
journalctl --disk-usage
df -h / /var/log
```

`rss` 是主进程常驻内存，单位 KiB；`MemoryCurrent` 是 cgroup 内存，单位字节，可能包含 RSS 以外的占用，关闭内存记账时可能无法读取。必要时单独检查 `trojan-fallback.service`。日志/磁盘增长与代理堆内存泄漏是不同问题，本安装器沿用宿主机 journald 保留策略。

如果内存持续增长，先保存核心版本、负载、PID/运行时长、采样数据及脱敏日志，再考虑重启。优先采用维护中的核心/修复版本，或为正常负载提供足够的 VM 内存。只在必要时重启对应服务作为临时缓解，并接受连接中断。硬性内存上限或提前重启都不是泄漏修复；随意设置过低上限可能造成掉线。仓库不默认设置固定内存上限或定时重启任务。本机功能测试不能代替你的 VM 上连续多天运行测试。

## 共存与统一入口

[统一安装器](https://github.com/sxmad/mofatizi-installer)提供 `1: all`、`2: trojan`、`3: hysteria2` 菜单，可分别指定域名、端口和密码文件；默认保留已有配置，显式使用 `--reinstall` 才覆盖。

Trojan TCP 443 可与 HY2 UDP 443 或 UDP 8443 共存。新版 HY2 改用 TCP 80 HTTP-01，默认不额外开启 TCP HTTPS 页面。两个安装器及续期任务共用 `/run/lock/trojan-cert-renew.lock`，也能与旧 Trojan 续期任务协调。运行期间不要删除该锁。证书、密码、服务分别管理，卸载一个不会删除另一个。

旧 HY2 部署可能仍占用 TCP 443 做 TLS-ALPN 与 HTTPS 页面，此时可加装 Trojan TCP 8443。指定的 TCP 端口被占用时会明确中断，不会停止 HY2 抢端口。如需释放旧 HY2 的 TCP 443，应显式使用新版重新安装 HY2，保留原域名、UDP 端口和密码，并接受短暂中断。

### 换 VM 保留密码

保持原域名/SNI、TCP 端口和密码，把 A 记录改到新 VM 并申请有效证书。客户端使用域名时通常无需改配置；DNS 缓存与现有连接仍可能导致短暂中断。新 VM 需放行 TCP 80 和所选 Trojan 端口。

```bash
sudo bash -c '
set -e
IFS= read -r -s -p "原 Trojan 密码: " trojan_password
printf "\n"
[[ -n "$trojan_password" ]] || exit 1
printf "%s\n" "$trojan_password" |
  bash <(curl -fsSL --proto "=https" --tlsv1.2 \
    https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) install \
    --domain trojan.example.com \
    --email you@example.com \
    --port 443 \
    --password-stdin
'
```

显式密码为空时拒绝安装，不会替换成随机密码；未指定 `--password-stdin` 的安装/重装仍会生成新密码。

## 排错

如果 HTTP-01 报 `Fetching http://...: Timeout during connect` 或 `Connection refused`，先核对 **`--domain` 实际填写的域名**是否解析到该 VM 公网 IP，再检查 GCP 和主机防火墙的公网入站 **TCP 80**。另一台 VM 安装成功不代表本机的 VPC 和防火墙目标标记也匹配。单有 `https-server` 标记不等于放行 TCP 80，放行 TCP 8443 或 UDP 443 也不能代替 HTTP-01 所需端口。修订号 `2026-10-18.3` 遇到此类错误会明确提示并中断；修复可达性后重新执行安装命令即可。后续续期仍需保留 TCP 80 放行规则。

`Could not find solver for: tls-alpn-01` 后面如果跟着 `use http-01 solver`，只是正常的信息提示：本安装器使用 HTTP-01。TCP 80 临时监听仅在签发/续期期间存在，因此安装器退出后连接被拒绝，本身不能证明是防火墙问题。

| 现象 | 检查 |
|---|---|
| ACME 超时或拒绝连接 | A/AAAA、CAA、TCP 80、公网防火墙目标、域名是否经过代理、80 是否被其他服务占用。 |
| Trojan 监听端口冲突 | `ss -ltnp`；可选 `--port 8443`，脚本不会替你关闭其他程序。 |
| 服务 active 但手机无网 | TCP 443/8443、防火墙规则目标、密码、Peer/SNI、证书校验与 Shadowrocket 路由；换客户端网络验证。 |
| HTTPS 页面可打开但代理失败 | 页面只证明 TLS 回落可用，还要检查认证及代理配置。 |
| 续期失败 | 查看续期 journal，修复 TCP 80/DNS；避免反复强制申请触发 CA 速率限制。 |
| BBR 未生效 | `sysctl net.ipv4.tcp_available_congestion_control` 与 `sysctl net.ipv4.tcp_congestion_control`；不支持时保留系统默认。 |
| 未指定版本却提示“只支持 v1.16.0” | 旧安装器的系统 `VERSION` 变量冲突；重新从 `main` 下载修订号 `2026-10-18.2` 或更新版本。固定 `714d541...` 地址不会获取修复。 |
| 无法查询官方版本 | 检查 VM 到 GitHub API 的访问及限流；重试或显式加 `--version v1.16.0`。 |

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

目前 `latest` 仍解析到 **Trojan-GFW v1.16.0**。该 release 发布于 2020 年，官方 Linux amd64 二进制报告 **OpenSSL 1.1.1g**。支持 `latest` 并不能让这个旧二进制的依赖获得更新；校验哈希只验证下载一致性，更新系统 OpenSSL 也不能假定会更新预编译二进制内的依赖。

Trojan 协议还有 [Xray](https://xtls.github.io/config/inbounds/trojan.html)、[sing-box](https://sing-box.sagernet.org/configuration/inbound/trojan/) 等实现。对新增长期部署，应优先评估仍在维护的实现及其稳定版。本仓库仍安装 Trojan-GFW，尚未实现向其他核心的配置与服务迁移。

## 可复现验证

```bash
bash tests/test_installer.sh
TROJAN_BIN=/path/to/trojan TEST_SERVER_PORT=8443 bash tests/test_local_proxy.sh
```

第一组不接触主机服务或 sysctl，覆盖 Debian/Ubuntu 安装前置流程、系统版本变量隔离、稳定版元数据及 SHA256 校验策略、端口、URI、BBR 跳过/加载/失败恢复，以及真实证书下的续期成功、错误域名、错误密钥、复制失败、热加载失败重试和停止状态。第二组用真实 Trojan 二进制和本地 CA 验证生成配置、8443 TLS、SOCKS 转发、新证书生效、换证前的连接仍可收发以及换证后的新连接。CI 还验证默认 TCP 443。

这些测试不替代真实 VM 上的 systemd、GCP 防火墙、ACME 公网签发和 Shadowrocket 实机验证；也不测量跨境线路性能。

参考：[Trojan 配置](https://trojan-gfw.github.io/trojan/config.html) · [SIGUSR1 热加载](https://trojan-gfw.github.io/trojan/usage.html) · [HTTP-01](https://letsencrypt.org/docs/challenge-types/#http-01-challenge) · [Google BBR](https://github.com/google/bbr) · [lego](https://go-acme.github.io/lego/)

## License

MIT
