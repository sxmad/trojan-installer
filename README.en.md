# trojan-installer

[简体中文](README.md) | [English](README.en.md)

Trojan-GFW installer for x86_64 Debian/Ubuntu Google Cloud VMs, with Shadowrocket URI and QR output. The default listener is **TCP 443**, configurable to **TCP 8443** or another port. Certificate issuance and renewal use **HTTP-01 on TCP 80**.

Installer revision: `2026-10-18.2`.

## Installation

First point your domain A record at the VM's static public IPv4 and supply your own domain and email. The commands below fetch the installer from `main`; `--version` selects the Trojan core, independently of the installer revision.

### One-command installation

Like HY2, download and install with one command. A regular user can run it through `sudo` without first entering a root shell. This example uses **8443**: allow inbound **TCP 80 and TCP 8443** and ensure those ports are not occupied by other services:

```bash
sudo bash -c 'bash <(curl -fsSL --proto "=https" --tlsv1.2 https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) install --domain trojan.example.com --email you@example.com --port 8443'
```

Omit `--port 8443` to use the default **443**, allowing TCP 80 and TCP 443 instead. Stock-kernel BBR is attempted by default; append `--no-bbr` before the closing single quote to skip it. A successful installation prints the Shadowrocket URI and QR code.

`--tlsv1.2` sets the minimum TLS version for the download and still permits TLS 1.3. It does not configure Trojan or Shadowrocket TLS versions.

### Download before installing

Alternatively, save the script for inspection and later management:

```bash
sudo -i
curl -fL --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh \
  -o /root/trojan-install.sh
bash /root/trojan-install.sh install \
  --domain trojan.example.com --email you@example.com
```

For 8443:

```bash
bash /root/trojan-install.sh install \
  --domain trojan.example.com --email you@example.com --port 8443
```

The installer installs dependencies, selects an official stable release and verifies its SHA256, obtains a certificate, creates systemd services, and prints connection details after local HTTPS and SOCKS egress tests pass. It does not change cloud/host firewall rules or reboot the VM.

## GCP and coexistence with HY2

| Purpose | Required inbound port |
|---|---|
| Default Trojan listener | TCP 443 |
| Trojan with `--port 8443` | TCP 8443 |
| Certificate issuance and future renewal, with either listener | TCP 80 |
| Existing HY2 | Keep its rules, e.g. UDP 443 plus TCP 443 for its HTTPS/certificates |

Both the GCP VPC firewall and any host firewall must permit the appropriate traffic. Match the VM's VPC and target network tag/service account. TCP 80 must be reachable by public ACME validators, not just your own client IP. Trojan does not need public UDP 8443. Do not expose the loopback fallback port 18080.

If `sxmad/hysteria2-installer` already owns TCP/UDP 443, use Trojan `--port 8443` and allow TCP 80. Prefer a separate Trojan hostname such as `trojan.example.com`. This script does not stop or modify HY2.

HTTP-01 always validates on public TCP 80; changing the proxy port cannot move that challenge to 8443. If another web server owns TCP 80, installation stops with an explanation; webroot and DNS-01 are not implemented. Changing ports alone does not guarantee better performance or reliability.

Requirements:

- x86_64 Debian 12/13 or Ubuntu LTS with systemd and access to package mirrors, GitHub releases, ACME and Google.
- An A record pointing directly to the VM; no Cloudflare orange-cloud proxy. This installer listens on IPv4 only and rejects AAAA records.
- A static external IPv4. Choose region and machine size from actual ISP routes, peak-hour loss and concurrent demand, rather than geographic distance alone.

## Options

| Option | Behavior |
|---|---|
| `--domain DOMAIN` | No default; prompt if missing. |
| `--email EMAIL` | No default; prompt for the ACME account email if missing. |
| `--port PORT` | Default 443; integer 1–65535, except 80 reserved for HTTP-01 and 18080 for fallback. Used consistently in config, URI, QR and self-tests. |
| `--no-bbr` | Skip BBR setup; leave existing settings unchanged, including already enabled BBR. |
| `--password-stdin` | Read 12–128 characters using letters, digits, `.`, `_`, `-`; otherwise generate 16 random hexadecimal characters. |
| `--version VERSION` | Default `latest` queries the official latest stable release. An explicit `vX.Y.Z`, such as `v1.16.0`, is also accepted. Prereleases are rejected. |
| `--no-page` | Skip the `asdfq` index while retaining fallback service and proxy tests. |
| `--yes` / `-y` | Skip the existing-install overwrite prompt. |
| `--keep-credentials` | Preserve URI, QR and config backups during uninstall. |
| `--help` | Show usage. |

With `--password-stdin`, missing identity values are read from `/dev/tty` rather than consuming the password pipe; absence of a terminal stops installation.

### Core versions and download verification

As of 2026-10-18, the official Trojan-GFW latest stable release is still **v1.16.0 (released 2020-06-10)**. `latest` queries that project's stable release; it does not switch to Xray, sing-box or another Trojan implementation, and does not schedule background core updates.

- By default the installer queries the GitHub Releases API. Network or rate-limit failures stop with a retry message instead of silently selecting another version.
- Explicit `--version v1.16.0` skips the metadata query, but downloading still requires access to GitHub.
- v1.16.0 uses the built-in verified SHA256. Other stable releases must provide the expected Linux amd64 asset and a GitHub SHA256 digest. Missing hashes or checksum mismatches stop installation before the downloaded binary is executed.

## BBR: attempted by default, optional

Trojan's outer transport is TCP. The installer tries to load the stock `tcp_bbr` module, applies `fq + bbr`, and persists it in `/etc/sysctl.d/99-trojan-installer-bbr.conf`. It does not install a kernel or third-party tuning scripts and requires no reboot. Unsupported kernels continue unchanged; failed application attempts to restore previous settings. An unmanaged file at the same path is not overwritten.

BBR may improve throughput and queueing delay on some high-latency or lossy paths; there is no fixed speed multiplier. It cannot fix outages, blocked IPs or expired certificates. These are system TCP defaults affecting other new TCP connections, not HY2's QUIC BBR or necessarily BBRv3. Changing the default qdisc does not replace existing NIC queues.

Add `--no-bbr` to the installation arguments to preserve current settings. In the one-command example, place it before the closing single quote. Inspect defaults and actual connections:

```bash
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
ss -tin
```

## Certificate renewal

`trojan-cert-renew.timer` checks daily and uses `lego --http renew --days 30` when renewal is due. It validates expiry, hostname and key matching, then deploys the files and sends `SIGUSR1` through `systemctl reload`. Trojan is not stopped or restarted: existing sessions keep their SSL context while new connections use the new certificate.

ACME failures or invalid new certificates leave deployed certificates intact. If issuance succeeds but copying or reload fails, the next run retries deployment even though the cached certificate is already fresh. A stopped Trojan remains stopped. Persistent failures still require attention; retries are not a guarantee of uninterrupted public connectivity.

```bash
systemctl list-timers trojan-cert-renew.timer
journalctl -u trojan-cert-renew.service --no-pager
# Run the same check manually; fresh, deployed certificates are not reissued.
systemctl start trojan-cert-renew.service
```

Reinstallation and binary updates still restart services and can interrupt existing connections. The no-stop behavior applies to scheduled renewal.

## Shadowrocket and self-tests

Success prints `trojan://password@domain:port?peer=domain&allowInsecure=0#trojan`, a terminal QR and `/root/trojan-domain.{txt,png}` (mode 600). Confirm type Trojan, the selected port, Peer/SNI equal to the domain, and certificate verification enabled.

Checks cover config parsing, the systemd main process owning the listener, local HTTPS fallback and Google `generate_204` returning 204 through a temporary Trojan client. The Python fallback binds only to `127.0.0.1:18080`; Trojan provides external TLS. Application UDP can be carried by Trojan while its client-to-server outer transport remains TCP/TLS.

Local success does not prove the client-to-GCP public route works. Test Shadowrocket on the actual client network, including peak-hour YouTube playback and sustained transfers.

## Management and migration

The following commands use `/root/trojan-install.sh` saved by the download-first method. If you used one-command installation, save the script using the download command above before running management operations.

```bash
bash /root/trojan-install.sh status
bash /root/trojan-install.sh restart
bash /root/trojan-install.sh update
```

`update` queries the latest stable release, then backs up and replaces the core while preserving config, password and listener port. Running services restart; stopped services remain stopped. Use `bash /root/trojan-install.sh update --version v1.16.0` to select a version explicitly. **It does not update the installer itself or regenerate installed renewal scripts. Without a newer upstream release, the core version stays the same.**

To migrate an old TLS-ALPN-01 installation, first allow TCP 80, download the revised installer and run `install` again (with `--port 8443` if needed). Reinstallation backs up the config and generates a new password and QR by default; use `--password-stdin` to keep your existing password. Still-valid lego certificates are reused and subsequently renewed by the new HTTP-01 timer. Failed installs attempt to restore previous config and service state.

## Troubleshooting

| Symptom | Check |
|---|---|
| ACME timeout / connection refused | A/AAAA, CAA, public TCP 80, firewall target, domain proxy and another process owning 80. |
| Trojan port occupied | Inspect `ss -ltnp`; select `--port 8443` if appropriate. Other services are not stopped for you. |
| Service active but phone has no Internet | TCP 443/8443, rule target, password, Peer/SNI, certificate validation, Shadowrocket routing and another client network. |
| HTTPS works but proxy fails | The page only validates TLS fallback; check proxy authentication and config. |
| Renewal failure | Read the renewal journal and fix TCP 80/DNS. Avoid repeated forced requests that may hit CA limits. |
| BBR unavailable | Inspect `sysctl net.ipv4.tcp_available_congestion_control` and `sysctl net.ipv4.tcp_congestion_control`. Unsupported kernels retain defaults. |
| "Only v1.16.0 is supported" without selecting a version | An older installer leaked the OS `VERSION` variable. Download revision `2026-10-18.2` or newer from `main`; the fixed `714d541...` URL always returns the older script. |
| Official version query failed | Check GitHub API connectivity and rate limits; retry or explicitly add `--version v1.16.0`. |

```bash
journalctl -b -u trojan.service --since '10 minutes ago' --no-pager
ss -H -ltnp 'sport = :8443'
```

Redact client addresses and authentication details before sharing logs.

## Uninstall

```bash
bash /root/trojan-install.sh uninstall
```

Removes installer-managed services, config, certificates, lego data, static files and installer-created user. Removes its BBR config and attempts to restore original TCP settings. Generated URI, QR and backups are removed unless `--keep-credentials` is supplied. Packages, DNS, GCP/host firewalls and other services are not managed. Immediate uninstall/reinstall can hit certificate issuance limits.

## Core maintenance limitation

Currently `latest` still resolves to **Trojan-GFW v1.16.0**. The release dates to 2020 and the official Linux amd64 binary reports **OpenSSL 1.1.1g**. Supporting `latest` does not update dependencies in that old binary. A matching checksum verifies download consistency, and updating the system OpenSSL must not be assumed to update dependencies inside this prebuilt binary.

The Trojan protocol is also implemented by [Xray](https://xtls.github.io/config/inbounds/trojan.html) and [sing-box](https://sing-box.sagernet.org/configuration/inbound/trojan/). For new long-term deployments, prioritize evaluating maintained implementations and their stable releases. This repository still installs Trojan-GFW and does not yet migrate config or services to another core.

## Reproducible validation

```bash
bash tests/test_installer.sh
TROJAN_BIN=/path/to/trojan TEST_SERVER_PORT=8443 bash tests/test_local_proxy.sh
```

The first suite uses no host services/sysctl changes and covers Debian/Ubuntu installation preflight, OS version variable isolation, stable release metadata and SHA256 policy, ports, URI, BBR skip/load/failure recovery, and real certificate fixtures for successful renewal, wrong hostname/key, copy failure, reload retries and stopped services. The second uses the real Trojan binary and a local CA to test generated config, TLS on 8443, SOCKS forwarding, the new certificate, an existing stream surviving reload, and new connections afterwards. CI also tests the default TCP 443 listener.

These tests do not replace real-VM systemd, GCP firewall, public ACME and Shadowrocket validation, and do not measure cross-border performance.

References: [Trojan config](https://trojan-gfw.github.io/trojan/config.html) · [SIGUSR1 reload](https://trojan-gfw.github.io/trojan/usage.html) · [HTTP-01](https://letsencrypt.org/docs/challenge-types/#http-01-challenge) · [Google BBR](https://github.com/google/bbr) · [lego](https://go-acme.github.io/lego/)

## License

MIT
