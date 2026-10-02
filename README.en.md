# trojan-installer

[简体中文](README.md) | [English](README.en.md)

A clean Trojan-GFW installer for Google Cloud VMs. It uses the official **Trojan-GFW v1.16.0**, TCP/TLS 443, the `lego` ACME client from Debian/Ubuntu repositories, and a `trojan://` link plus QR code that can be imported into Shadowrocket. There are no default domain or email values; one command completes dependencies, certificates, services, self-tests, and connection output.

[Install](#one-click-installation) · [Preparation](#required-preparation) · [Options](#installation-options) · [Manage](#service-management-and-updates) · [Uninstall](#uninstall-and-retest) · [Troubleshooting](#troubleshooting)

## Design choices

- The core is the official Trojan-GFW v1.16.0. Old Trojan-Go builds and unknown one-click scripts are not installed.
- Trojan-GFW is TCP/TLS and needs **TCP 443 only**. Hysteria2’s UDP 443 rule is not needed.
- Certificates use `lego` with **TLS-ALPN-01**. `lego` temporarily owns TCP 443 during issuance, then Trojan takes it back. Nginx, Certbot, and public TCP 80 are not required.
- Trojan’s HTTPS fallback connects to a Python static server bound only to `127.0.0.1:18080`; the page content is `asdfq` and the Python server is not public.
- If the kernel exposes BBR, the installer writes `/etc/sysctl.d/99-trojan-installer-bbr.conf` and attempts `fq + bbr`. Unsupported kernels only produce a warning; no third-party tuning script is installed.

## Recommended Google Cloud VM

For up to 15 users with speed as the priority, start with Debian 13, `e2-standard-2` (2 vCPUs / 8 GB), a 30 GB `pd-balanced` disk, Premium Tier, and a static external IPv4. Use `e2-standard-4` (4 vCPUs / 16 GB) for frequent simultaneous 4K streaming or downloads. The disk stores the OS, certificates, and logs, not proxy traffic.

## One-click installation

Installer revision: `2026-10-02.7`. Supply your own domain and email:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) \
  install --domain trojan.example.com --email you@example.com
```

The script installs `lego`, `qrencode`, and other dependencies, downloads and verifies the pinned official Trojan binary, obtains a certificate, creates least-privilege systemd services, enables renewal, and prints the password, URI, and QR only after the local HTTPS fallback and Trojan SOCKS5 egress tests pass.

## Required preparation

1. Point an A record at the VM’s static public IPv4. Remove a stale AAAA record that points elsewhere; the installer stops when it sees AAAA because ACME may choose the wrong IPv6. Do not use Cloudflare’s orange-cloud proxy.
2. Allow **TCP 443** in the Google Cloud VPC firewall. The rule target must match this VM’s VPC, network tag, or service account, and the source ranges must cover clients and Let’s Encrypt.
3. Use an official x86_64 Debian 12/13 or Ubuntu LTS image and allow the VM to reach Debian package mirrors, the GitHub release, and the ACME service.

The installer does not change Google Cloud firewall rules, disable UFW/firewalld, install Nginx, upload account credentials, or reboot the VM. During issuance Trojan stops for a few seconds while `lego` uses TCP 443 for the challenge.

## Installation options

| Option | Behavior |
|---|---|
| `--domain DOMAIN` | No default; prompt when omitted. |
| `--email EMAIL` | No default; prompt for the ACME account email when omitted. |
| `--password-stdin` | Read a 12–128-character password from stdin using letters, digits, `.`, `_`, or `-`; otherwise generate 16 hexadecimal characters. |
| `--version v1.16.0` | Only the pinned official version is accepted; omission still uses v1.16.0. |
| `--no-page` | Skip the `asdfq` index page while keeping the local HTTPS fallback and proxy self-test. |
| `--yes` / `-y` | Skip the overwrite confirmation; certificate errors and self-tests still stop. |
| `--keep-credentials` | Keep installer-generated URI, QR files, and config backups during uninstall; these are removed by default. |
| `--help` | Show usage and the revision. |

Missing domain/email values are read from the terminal. With `--password-stdin`, identity values are read only from `/dev/tty`, so the password pipe is not consumed; without a terminal, installation stops.

## Output and self-tests

A successful install prints:

- a Shadowrocket URI: `trojan://password@domain:443?peer=domain&allowInsecure=0#trojan`; `peer` is the TLS SNI;
- a Unicode QR code for Web SSH;
- `/root/trojan-domain.png` and `/root/trojan-domain.txt`, both mode `600`.

Before printing it checks:

1. `trojan -t -c /etc/trojan/server.json`;
2. an active `trojan.service` whose process listens on TCP 443;
3. `https://domain/` returning the local `asdfq` page;
4. a temporary official Trojan client using SOCKS5 to reach Google `generate_204` and receive HTTP 204.

Any failure withholds the new URI and QR. A working page proves TLS fallback only; Shadowrocket still needs a real client test.

Certificate failures show the `lego` log and offer up to three choices of `1. repair and retry` or `2. abort`. Domain, DNS, CAA, 443 firewall, and CA rate-limit problems must be fixed outside the VM; the script does not guess or change cloud rules. Rate limits stop immediately to avoid repeated requests.

## Service management and updates

```bash
systemctl --no-pager --full status trojan.service
systemctl is-enabled trojan.service
systemctl is-active trojan.service
systemctl list-timers trojan-cert-renew.timer
```

`trojan-cert-renew.timer` checks daily. When renewal is due it stops Trojan, lets `lego` temporarily bind TCP 443, copies the new certificate, and starts Trojan again. Failures try to restore the service and are recorded in the journal.

Update the pinned official binary while preserving the current config and password:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) update
```

`update` backs up the config and checks the new binary, config, and TCP 443. A service that was stopped remains stopped; no new QR is generated.

## Uninstall and retest

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sxmad/trojan-installer/main/install.sh) uninstall
```

After confirmation it stops and removes Trojan, the fallback service, the renewal timer, config, certificate copies, static page, lego account/certificate data, and the `trojan` user and BBR file created by this installer. It also removes installer-generated `/root/trojan-*.{txt,png}` files and all installer config backups by default; use `--keep-credentials` to retain them. Pre-existing Trojan users, binaries, and files outside installer-managed paths are kept. Packages, DNS, and Google Cloud firewall rules remain.

A reinstall immediately after uninstall requests a new ACME certificate and may hit CA rate limits. Use a new VM to test first-boot dependencies and issuance; no VM reboot is required.

## First Shadowrocket connection

Scan or import the URI and confirm: type Trojan, domain address, port `443`, the newly generated password, Peer/SNI equal to the domain, and certificate verification enabled. For the first test, temporarily use global Proxy routing, then restore your own rules. Trojan does not need UDP 443.

## Troubleshooting

| Symptom | Check |
|---|---|
| `lego` challenge timeout / connection refused | A record, stale AAAA, inbound TCP 443, firewall target, domain proxy, and any process already using 443. |
| TCP 443 is occupied | Run `ss -ltnp`; the installer does not stop or overwrite another service. |
| Service is active but the phone has no Internet | Check TCP 443, the QR’s current password, Peer/SNI, Shadowrocket routing, and another client network. |
| HTTPS page works but proxy does not | The page tests TLS fallback only; check the password, URI, and client config. |
| `apt-get` prints `Get`, `Hit`, or `Reading package lists... Done` | Dependency logs only; wait for issuance, self-tests, and the QR. |
| BBR is not enabled | Check `cat /proc/sys/net/ipv4/tcp_available_congestion_control`; unsupported kernels keep the system default. |

Logs may contain client addresses or authentication-related fields. Redact them before sharing:

```bash
journalctl -b -u trojan.service --since '10 minutes ago' --no-pager
journalctl -b -u trojan-cert-renew.service --no-pager
ss -H -ltnp 'sport = :443'
```

## Security and auditability

- The script pins the official Trojan-GFW v1.16.0 URL and release tarball SHA256; failed downloads or checksums stop installation.
- The config is `root:trojan` mode `0640`; the private-key copy is `root:trojan` mode `0640`; the service runs as `trojan` with only the capability needed to bind 443.
- It does not call third-party installer scripts, publish client archives, disable host firewalls, or install external BBR scripts.
- Trojan provides TCP/TLS proxying only; speed depends mainly on the Google Cloud region, ISP route, and TCP loss.

## Validation scope

The repository includes reproducible local tests: `tests/test_installer.sh` checks syntax, help, domain normalization, password generation, and input rejection; `TROJAN_BIN=/path/to/trojan tests/test_local_proxy.sh` uses a real Trojan-GFW binary to check config parsing, TLS fallback, authentication, and SOCKS5 forwarding. The installer itself pins the release SHA256, runs `trojan -t`, and checks the generated systemd services and listeners. Production still requires TLS-ALPN issuance on a real Google Cloud VM and a Shadowrocket connection test.

References:

- [Trojan-GFW configuration](https://trojan-gfw.github.io/trojan/config.html)
- [Trojan-GFW releases](https://github.com/trojan-gfw/trojan/releases)
- [lego documentation](https://go-acme.github.io/lego/)
- [Let's Encrypt TLS-ALPN-01](https://letsencrypt.org/docs/challenge-types/#tls-alpn-01)

## License

MIT
