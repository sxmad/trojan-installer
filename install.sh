#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="trojan-installer"
readonly SCRIPT_VERSION="2026-10-02.3"
readonly TROJAN_VERSION="1.16.0"
readonly TROJAN_TARBALL="trojan-${TROJAN_VERSION}-linux-amd64.tar.xz"
readonly TROJAN_URL="https://github.com/trojan-gfw/trojan/releases/download/v${TROJAN_VERSION}/${TROJAN_TARBALL}"
readonly TROJAN_SHA256="daad1ab6edd3f89066c5e1f42c6618b2f8cb59b7ba375dfb043d0c62c9e254ea"
readonly BINARY="/usr/local/bin/trojan"
readonly CONFIG_DIR="/etc/trojan"
readonly CONFIG_FILE="${CONFIG_DIR}/server.json"
readonly CERT_FILE="${CONFIG_DIR}/cert.pem"
readonly KEY_FILE="${CONFIG_DIR}/key.pem"
readonly SERVICE="trojan.service"
readonly FALLBACK_SERVICE="trojan-fallback.service"
readonly FALLBACK_PORT="18080"
readonly HOME_DIR="/var/lib/trojan"
readonly STATIC_DIR="${HOME_DIR}/masquerade"
readonly LEGO_DIR="${HOME_DIR}/lego"
readonly STATE_DIR="/var/lib/trojan-installer"
readonly STATE_FILE="${STATE_DIR}/state"
readonly BACKUP_DIR="/var/backups/trojan-installer"
readonly RENEW_SCRIPT="/usr/local/sbin/trojan-renew-cert"
readonly RENEW_SERVICE="trojan-cert-renew.service"
readonly RENEW_TIMER="trojan-cert-renew.timer"

ACTION="install"
DOMAIN=""
EMAIL=""
PASSWORD=""
PASSWORD_FROM_STDIN=0
YES=0
VERSION=""
STATIC_PAGE=1
CERT_CREATED=0
BBR_CREATED=0
BBR_OLD_CC=""
BBR_OLD_QDISC=""
LEGO_BIN=""
USER_PREEXISTED=1
BINARY_PREEXISTED=1
BINARY_BACKUP=""
INSTALL_BACKUP_DIR=""
PREV_SERVICE_ACTIVE=0
PREV_FALLBACK_ACTIVE=0
INSTALL_RESTORE=0
NEW_SERVICES_STARTED=0
USER_CREATED=0
FRESH_INSTALL=0

die() { printf '%s: %s\n' "${SCRIPT_NAME}" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "${SCRIPT_NAME}" "$*" >&2; }
info() { printf '%s\n' "$*"; }
on_error() { printf '%s: failed at line %s\n' "${SCRIPT_NAME}" "$1" >&2; }
trap 'on_error "$LINENO"' ERR

require_root() { [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行。"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "缺少命令 $1。"; }

usage() {
  printf 'Installer revision: %s\n\n' "${SCRIPT_VERSION}"
  cat <<'EOF'
Trojan-GFW clean installer

Usage:
  install.sh [install] [options]
  install.sh update
  install.sh uninstall [--yes]
  install.sh start | stop | restart | status

Install options:
  --domain DOMAIN       TLS certificate domain (no default; prompt if omitted)
  --email EMAIL         ACME email (no default; prompt if omitted)
  --password-stdin      Read a custom 12-128-character password from stdin
  --version VERSION     Only the pinned official version v1.16.0 is supported
  --no-page             Do not create the local HTTPS fallback page
  --yes                 Do not ask before replacing an existing installation
  -h, --help            Show this help

The installer uses the official Trojan-GFW v1.16.0 binary, TCP 443, a
Let's Encrypt TLS-ALPN-01 certificate, and a local Python static fallback.
It does not install Nginx, Docker, panels, or third-party scripts. Trojan clients
use a TCP/TLS connection; UDP 443 is not required.
EOF
}

parse_args() {
  local arg
  while (($#)); do
    arg="$1"
    case "${arg}" in
      install) ACTION=install ;;
      update) ACTION=update ;;
      uninstall|remove) ACTION=uninstall ;;
      start|stop|restart|status) ACTION="${arg}" ;;
      --domain) (($# >= 2)) || die "--domain 需要参数。"; DOMAIN="$2"; shift ;;
      --email) (($# >= 2)) || die "--email 需要参数。"; EMAIL="$2"; shift ;;
      --password-stdin) PASSWORD_FROM_STDIN=1 ;;
      --version) (($# >= 2)) || die "--version 需要参数。"; VERSION="$2"; shift ;;
      --no-page|--no-masquerade) STATIC_PAGE=0 ;;
      --yes|-y) YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：${arg}。使用 --help 查看用法。" ;;
    esac
    shift
  done
}

collect_identity() {
  DOMAIN="${DOMAIN,,}"
  [[ -n "${DOMAIN}" && -n "${EMAIL}" ]] && return 0
  local fd=0
  if (( PASSWORD_FROM_STDIN )); then
    if ! { exec {fd}</dev/tty; } 2>/dev/null; then
      die "缺少域名或邮箱且没有交互终端；使用 --password-stdin 时请同时指定 --domain 和 --email。"
    fi
  fi
  if [[ -z "${DOMAIN}" ]] && ! IFS= read -r -u "${fd}" -p "域名: " DOMAIN; then
    die "未读取到域名，请使用 --domain 指定，已取消。"
  fi
  if [[ -z "${EMAIL}" ]] && ! IFS= read -r -u "${fd}" -p "ACME 邮箱: " EMAIL; then
    die "未读取到邮箱，请使用 --email 指定，已取消。"
  fi
  ((fd == 0)) || exec {fd}<&-
  DOMAIN="${DOMAIN,,}"
  [[ -n "${DOMAIN}" ]] || die "域名不能为空。"
  [[ -n "${EMAIL}" ]] || die "邮箱不能为空。"
}

valid_domain() {
  local name="$1" label labels=()
  [[ "${name}" != .* && "${name}" != *. && "${name}" != *..* ]] || return 1
  ((${#name} <= 220)) || return 1
  IFS='.' read -r -a labels <<<"${name}"
  ((${#labels[@]} >= 2)) || return 1
  for label in "${labels[@]}"; do
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
  done
}

validate_inputs() {
  [[ -n "${DOMAIN}" ]] || die "域名不能为空。"
  [[ -n "${EMAIL}" ]] || die "邮箱不能为空。"
  valid_domain "${DOMAIN}" || die "域名格式不正确：${DOMAIN}"
  [[ "${EMAIL}" =~ ^[A-Za-z0-9.!_%+\-]+@[A-Za-z0-9.-]+$ ]] || die "邮箱格式不正确：${EMAIL}"
  local localpart="${EMAIL%@*}" maildomain="${EMAIL#*@}"
  [[ "${localpart}" != .* && "${localpart}" != *. && "${localpart}" != *..* ]] || die "邮箱格式不正确：${EMAIL}"
  valid_domain "${maildomain}" || die "邮箱域名格式不正确：${EMAIL}"
  if [[ -n "${VERSION}" && "${VERSION}" != "v${TROJAN_VERSION}" ]]; then
    die "当前安装器只支持官方 Trojan-GFW v${TROJAN_VERSION}。"
  fi
  if (( PASSWORD_FROM_STDIN )); then
    IFS= read -r PASSWORD || die "未从标准输入读取到密码，已取消。"
  fi
  if [[ -z "${PASSWORD}" ]]; then
  PASSWORD="$(openssl rand -hex 8)"
  fi
  [[ "${PASSWORD}" =~ ^[A-Za-z0-9._-]{12,128}$ ]] || die "密码必须为 12-128 位，只能包含字母、数字、点、下划线或短横线。"
}

check_platform() {
  [[ "$(uname -m)" == x86_64 ]] || die "当前仅支持 x86_64 Linux VM。"
  [[ -r /etc/os-release ]] || die "无法识别操作系统。"
  . /etc/os-release
  case "${ID:-}" in debian|ubuntu) ;; *) die "当前支持 Debian/Ubuntu；请使用带 systemd 的官方镜像。" ;; esac
  [[ -d /run/systemd/system ]] || die "此系统没有运行 systemd。"
}

install_prerequisites() {
  local packages=()
  command -v curl >/dev/null 2>&1 || packages+=(curl)
  command -v openssl >/dev/null 2>&1 || packages+=(openssl)
  command -v qrencode >/dev/null 2>&1 || packages+=(qrencode)
  command -v ss >/dev/null 2>&1 || packages+=(iproute2)
  command -v lego >/dev/null 2>&1 || packages+=(lego)
  command -v python3 >/dev/null 2>&1 || packages+=(python3)
  command -v sysctl >/dev/null 2>&1 || packages+=(procps)
  command -v flock >/dev/null 2>&1 || packages+=(util-linux)
  command -v tar >/dev/null 2>&1 || packages+=(tar)
  command -v xz >/dev/null 2>&1 || packages+=(xz-utils)
  command -v sha256sum >/dev/null 2>&1 || packages+=(coreutils)
  command -v timeout >/dev/null 2>&1 || packages+=(coreutils)
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
  if ((${#packages[@]} == 0)); then
    LEGO_BIN="$(command -v lego || true)"
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || die "请先安装 apt-get 依赖：${packages[*]}。"
  info "使用 apt-get 安装必要依赖：${packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates "${packages[@]}"
  LEGO_BIN="$(command -v lego || true)"
}

configure_bbr() {
  command -v sysctl >/dev/null 2>&1 || { warn "未找到 sysctl，跳过 BBR。"; return 0; }
  [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] || { warn "内核未提供拥塞控制列表，跳过 BBR。"; return 0; }
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control || {
    warn "当前内核不支持 BBR，继续使用系统默认 TCP 拥塞控制。"
    return 0
  }
  local conf=/etc/sysctl.d/99-trojan-installer-bbr.conf
  if [[ -e "${conf}" ]] && ! grep -q 'Managed by trojan-installer' "${conf}"; then
    warn "${conf} 已由其他配置管理，跳过覆盖。"
    return 0
  fi
  if [[ ! -e "${conf}" ]]; then
    BBR_OLD_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    BBR_OLD_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    cat >"${conf}" <<'EOF'
# Managed by trojan-installer: use BBR when the kernel supports it.
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    chmod 0644 "${conf}"
    BBR_CREATED=1
  fi
  if sysctl -p "${conf}" >/dev/null 2>&1 && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == bbr ]]; then
    info "已启用内核 BBR（Trojan 使用 TCP）。"
  else
    warn "BBR 配置文件已写入，但当前内核未能切换到 bbr；继续安装。"
  fi
}

write_state() {
  install -d -m 0700 "${STATE_DIR}"
  printf 'state_version=2\ndomain=%s\ncert_created=%s\nbbr_created=%s\nbbr_old_cc=%s\nbbr_old_qdisc=%s\nuser_preexisted=%s\nbinary_preexisted=%s\n' \
    "${DOMAIN}" "${CERT_CREATED}" "${BBR_CREATED}" "${BBR_OLD_CC}" "${BBR_OLD_QDISC}" \
    "${USER_PREEXISTED:-1}" "${BINARY_PREEXISTED:-1}" >"${STATE_FILE}"
  [[ -z "${BINARY_BACKUP}" ]] || printf 'binary_backup=%s\n' "${BINARY_BACKUP}" >>"${STATE_FILE}"
  chmod 0600 "${STATE_FILE}"
}

backup_existing() {
  [[ -f "${CONFIG_FILE}" || -f "${CERT_FILE}" || -f "${KEY_FILE}" ]] || return 0
  install -d -m 0700 "${BACKUP_DIR}"
  INSTALL_BACKUP_DIR="${BACKUP_DIR}/install-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "${INSTALL_BACKUP_DIR}"
  [[ -f "${CONFIG_FILE}" ]] && cp -p "${CONFIG_FILE}" "${INSTALL_BACKUP_DIR}/server.json"
  [[ -f "${CERT_FILE}" ]] && cp -p "${CERT_FILE}" "${INSTALL_BACKUP_DIR}/cert.pem"
  [[ -f "${KEY_FILE}" ]] && cp -p "${KEY_FILE}" "${INSTALL_BACKUP_DIR}/key.pem"
  info "已备份现有配置：${INSTALL_BACKUP_DIR}"
}

confirm_existing() {
  [[ -e "${CONFIG_FILE}" || -e "${BINARY}" || -e "/etc/systemd/system/${SERVICE}" ]] || return 0
  ((YES)) && return 0
  local answer
  read -r -p "检测到已有 Trojan 安装，备份后覆盖？[y/N] " answer || die "已取消。"
  [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消。"
}

download_binary() {
  local tmp tarball extracted staged
  tmp="$(mktemp -d)"
  tarball="${tmp}/${TROJAN_TARBALL}"
  extracted="${tmp}/extract"
  staged="${BINARY}.new.$$"
  mkdir "${extracted}"
  info "下载并校验官方 Trojan-GFW v${TROJAN_VERSION}..."
  if ! curl -fL --retry 2 --connect-timeout 15 --max-time 120 -o "${tarball}" "${TROJAN_URL}"; then
    rm -rf -- "${tmp}"
    die "官方 Trojan 下载失败。"
  fi
  printf '%s  %s\n' "${TROJAN_SHA256}" "${tarball}" | sha256sum -c - >/dev/null || {
    rm -rf -- "${tmp}"
    die "官方 Trojan 文件 SHA256 校验失败。"
  }
  tar --no-same-owner -xJf "${tarball}" -C "${extracted}"
  [[ -x "${extracted}/trojan/trojan" ]] || { rm -rf -- "${tmp}"; die "官方压缩包缺少 Trojan 可执行文件。"; }
  install -Dm755 "${extracted}/trojan/trojan" "${staged}"
  "${staged}" -v >/dev/null 2>&1 || { rm -rf -- "${tmp}"; rm -f "${staged}"; die "Trojan 可执行文件自检失败。"; }
  if [[ -e "${BINARY}" && -z "${BINARY_BACKUP}" ]]; then
    install -d -m 0700 "${BACKUP_DIR}"
    BINARY_BACKUP="${BACKUP_DIR}/trojan-binary-$(date +%Y%m%d-%H%M%S)"
    cp -p "${BINARY}" "${BINARY_BACKUP}"
  fi
  mv -f "${staged}" "${BINARY}"
  rm -rf -- "${tmp}"
}

write_static_page() {
  install -d -o trojan -g trojan -m 0755 "${STATIC_DIR}"
  if (( ! STATIC_PAGE )); then
    rm -f "${STATIC_DIR}/index.html"
    return 0
  fi
  cat >"${STATIC_DIR}/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>asdfq</title></head>
<body>asdfq</body>
</html>
EOF
  chown trojan:trojan "${STATIC_DIR}/index.html"
  chmod 0644 "${STATIC_DIR}/index.html"
}

write_fallback_service() {
  cat >"/etc/systemd/system/${FALLBACK_SERVICE}" <<EOF
[Unit]
Description=Trojan local static fallback
After=network.target

[Service]
Type=simple
User=trojan
Group=trojan
ExecStart=/usr/bin/python3 -m http.server ${FALLBACK_PORT} --bind 127.0.0.1 --directory ${STATIC_DIR}
Restart=on-failure
RestartSec=2s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=${STATIC_DIR}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${FALLBACK_SERVICE}" >/dev/null
  if ! systemctl restart "${FALLBACK_SERVICE}"; then
    journalctl -u "${FALLBACK_SERVICE}" -n 30 --no-pager >&2 || true
    die "本地回落服务无法监听 127.0.0.1:${FALLBACK_PORT}；请检查端口和 Python。"
  fi
}

write_config() {
  install -d -o root -g trojan -m 0750 "${CONFIG_DIR}"
  local tmp="${CONFIG_FILE}.tmp.$$"
  cat >"${tmp}" <<EOF
{
    "run_type": "server",
    "local_addr": "0.0.0.0",
    "local_port": 443,
    "remote_addr": "127.0.0.1",
    "remote_port": ${FALLBACK_PORT},
    "password": ["${PASSWORD}"],
    "log_level": 1,
    "ssl": {
        "cert": "${CERT_FILE}",
        "key": "${KEY_FILE}",
        "key_password": "",
        "cipher": "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384",
        "cipher_tls13": "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
        "prefer_server_cipher": true,
        "alpn": ["http/1.1"],
        "reuse_session": true,
        "session_ticket": false,
        "session_timeout": 600,
        "plain_http_response": "",
        "curves": "",
        "dhparam": ""
    },
    "tcp": {
        "prefer_ipv4": true,
        "no_delay": true,
        "keep_alive": true,
        "reuse_port": false,
        "fast_open": false,
        "fast_open_qlen": 20
    },
    "mysql": {"enabled": false}
}
EOF
  chown root:trojan "${tmp}"
  chmod 0640 "${tmp}"
  mv -f "${tmp}" "${CONFIG_FILE}"
}

sync_certificate() {
  local cert="${LEGO_DIR}/certificates/${DOMAIN}.crt" key="${LEGO_DIR}/certificates/${DOMAIN}.key"
  [[ -s "${cert}" && -s "${key}" ]] || die "Let’s Encrypt 证书文件不完整。"
  install -d -o root -g trojan -m 0750 "${CONFIG_DIR}"
  install -o root -g trojan -m 0644 "${cert}" "${CERT_FILE}.new"
  install -o root -g trojan -m 0640 "${key}" "${KEY_FILE}.new"
  mv -f "${CERT_FILE}.new" "${CERT_FILE}"
  mv -f "${KEY_FILE}.new" "${KEY_FILE}"
}

cert_valid() {
  local cert="${LEGO_DIR}/certificates/${DOMAIN}.crt"
  [[ -s "${cert}" ]] || return 1
  openssl x509 -in "${cert}" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
  openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null | grep -Fq "DNS:${DOMAIN}"
}

obtain_certificate() {
  if cert_valid; then
    info "复用仍有效的 Let’s Encrypt 证书。"
    sync_certificate
    return 0
  fi
  CERT_CREATED=1
  local attempt=0 log="$(mktemp)" status=0 acme_action=run
  if [[ -s "${LEGO_DIR}/certificates/${DOMAIN}.crt" && -s "${LEGO_DIR}/certificates/${DOMAIN}.key" ]]; then
    acme_action=renew
  fi
  while ((attempt < 3)); do
    ((attempt += 1))
    if [[ "${acme_action}" == renew ]]; then
      info "续期 Let’s Encrypt TLS-ALPN-01 证书（第 ${attempt}/3 次，需要 TCP 443）..."
    else
      info "申请 Let’s Encrypt TLS-ALPN-01 证书（第 ${attempt}/3 次，需要 TCP 443）..."
    fi
    status=0
    if [[ "${acme_action}" == renew ]]; then
      timeout 180s "${LEGO_BIN}" --path "${LEGO_DIR}" --domains "${DOMAIN}" --tls renew --days 30 >"${log}" 2>&1 || status=$?
    else
      timeout 180s "${LEGO_BIN}" --accept-tos --path "${LEGO_DIR}" --email "${EMAIL}" \
        --domains "${DOMAIN}" --tls run >"${log}" 2>&1 || status=$?
    fi
    if ((status == 0)) && cert_valid; then
      cat "${log}"
      rm -f "${log}"
      sync_certificate
      return 0
    fi
    cat "${log}" >&2
    if grep -Eiq 'rate.?limit|too many|retry.?after' "${log}"; then
      rm -f "${log}"
      die "证书申请触发 CA 速率限制；请等待后再试，安装已中断。"
    fi
    if ((attempt >= 3)); then
      rm -f "${log}"
      die "证书申请连续失败 3 次，安装已中断。"
    fi
    local answer
    if [[ -t 0 ]]; then
      read -r -p "证书申请似乎是临时错误。1. 修复并重试  2. 中断: " answer || answer=2
    else
      answer=2
    fi
    [[ "${answer}" == 1 ]] || { rm -f "${log}"; die "已中断，未生成连接信息。"; }
    sleep $((attempt * 5))
  done
}

write_renewal_service() {
  [[ -n "${LEGO_BIN}" && -x "${LEGO_BIN}" ]] || die "未找到 lego，可先执行 apt-get install lego。"
  cat >"${RENEW_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
domain='${DOMAIN}'
lego_dir='${LEGO_DIR}'
cert_file='${CERT_FILE}'
key_file='${KEY_FILE}'
lego_bin='${LEGO_BIN}'
exec 9>/run/lock/trojan-cert-renew.lock
flock -n 9 || exit 0
cert="\${lego_dir}/certificates/\${domain}.crt"
if [[ -s "\${cert}" ]] && openssl x509 -in "\${cert}" -noout -checkend 2592000 >/dev/null 2>&1; then
  exit 0
fi
restart=0
if systemctl is-active --quiet trojan.service; then
  systemctl stop trojan.service
  restart=1
fi
restore() {
  local rc=$?
  trap - EXIT
  if ((restart)); then
    if ! systemctl start trojan.service || ! systemctl is-active --quiet trojan.service; then
      echo 'trojan-cert-renew: failed to restore trojan.service' >&2
      rc=1
    fi
  fi
  exit "${rc}"
}
trap restore EXIT
timeout 180s "\${lego_bin}" --path "\${lego_dir}" --domains "\${domain}" --tls renew --days 30
install -o root -g trojan -m 0644 "\${lego_dir}/certificates/\${domain}.crt" "\${cert_file}.new"
install -o root -g trojan -m 0640 "\${lego_dir}/certificates/\${domain}.key" "\${key_file}.new"
mv -f "\${cert_file}.new" "\${cert_file}"
mv -f "\${key_file}.new" "\${key_file}"
EOF
  chmod 0750 "${RENEW_SCRIPT}"
  cat >"/etc/systemd/system/${RENEW_SERVICE}" <<EOF
[Unit]
Description=Renew Trojan TLS certificate
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=240s
ExecStart=${RENEW_SCRIPT}
EOF
  cat >"/etc/systemd/system/${RENEW_TIMER}" <<EOF
[Unit]
Description=Daily Trojan TLS certificate renewal check

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable "${RENEW_TIMER}" >/dev/null
}

write_service() {
  cat >"/etc/systemd/system/${SERVICE}" <<EOF
[Unit]
Description=Trojan-GFW server
Documentation=https://trojan-gfw.github.io/trojan/config.html
After=network-online.target nss-lookup.target ${FALLBACK_SERVICE}
Wants=network-online.target

[Service]
Type=simple
User=trojan
Group=trojan
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${BINARY} ${CONFIG_FILE}
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure
RestartSec=2s
LimitNOFILE=51200
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE}" >/dev/null
}

config_test() { "${BINARY}" -t -c "${CONFIG_FILE}" >/dev/null; }

port_ready() {
  ss -H -ltnp 2>/dev/null | awk -v p=":443" '$1=="LISTEN" && ($4 ~ (p "$" ) || $5 ~ (p "$")) && /trojan/ {ok=1} END{exit !ok}'
}

service_diagnostics() {
  warn "最近的 Trojan 服务日志："
  journalctl -u "${SERVICE}" -n 80 --no-pager >&2 || true
  warn "请确认域名、TCP 443、防火墙目标和证书权限。"
}

restore_previous_install() {
  local rc=$?
  trap - EXIT
  if ((INSTALL_RESTORE)); then
    systemctl stop "${SERVICE}" "${FALLBACK_SERVICE}" >/dev/null 2>&1 || true
    if [[ -n "${INSTALL_BACKUP_DIR}" ]]; then
      [[ -f "${INSTALL_BACKUP_DIR}/server.json" ]] && cp -p "${INSTALL_BACKUP_DIR}/server.json" "${CONFIG_FILE}"
      [[ -f "${INSTALL_BACKUP_DIR}/cert.pem" ]] && cp -p "${INSTALL_BACKUP_DIR}/cert.pem" "${CERT_FILE}"
      [[ -f "${INSTALL_BACKUP_DIR}/key.pem" ]] && cp -p "${INSTALL_BACKUP_DIR}/key.pem" "${KEY_FILE}"
    fi
    if ((BINARY_PREEXISTED)) && [[ -s "${BINARY_BACKUP}" ]]; then cp -p "${BINARY_BACKUP}" "${BINARY}"; fi
    if ((FRESH_INSTALL)); then
      if ((USER_CREATED)); then
        userdel trojan >/dev/null 2>&1 || true
      fi
      if ((BBR_CREATED)); then
        [[ -z "${BBR_OLD_CC}" ]] || sysctl -w "net.ipv4.tcp_congestion_control=${BBR_OLD_CC}" >/dev/null 2>&1 || true
        [[ -z "${BBR_OLD_QDISC}" ]] || sysctl -w "net.core.default_qdisc=${BBR_OLD_QDISC}" >/dev/null 2>&1 || true
        rm -f /etc/sysctl.d/99-trojan-installer-bbr.conf
      fi
      if (( ! BINARY_PREEXISTED )); then rm -f "${BINARY}"; fi
      rm -f "/etc/systemd/system/${SERVICE}" "/etc/systemd/system/${FALLBACK_SERVICE}" \
        "/etc/systemd/system/${RENEW_SERVICE}" "/etc/systemd/system/${RENEW_TIMER}" "${RENEW_SCRIPT}"
      systemctl daemon-reload >/dev/null 2>&1 || true
      rm -f "${CONFIG_FILE}" "${CERT_FILE}" "${KEY_FILE}"
      rm -rf -- "${STATIC_DIR}" "${LEGO_DIR}"
      [[ -d "${CONFIG_DIR}" ]] && rmdir "${CONFIG_DIR}" 2>/dev/null || true
      rm -rf -- "${STATE_DIR}"
    fi
    if ((PREV_FALLBACK_ACTIVE)); then systemctl start "${FALLBACK_SERVICE}" >/dev/null 2>&1 || true; fi
    if ((PREV_SERVICE_ACTIVE)); then systemctl start "${SERVICE}" >/dev/null 2>&1 || true; fi
  fi
  exit "${rc}"
}

local_selftest() (
  trap - ERR
  local dir client_port client_pid="" code="" i
  dir="$(mktemp -d /tmp/trojan-selftest.XXXXXXXX)"
  cleanup() { [[ -z "${client_pid}" ]] || kill "${client_pid}" 2>/dev/null || true; [[ -z "${client_pid}" ]] || wait "${client_pid}" 2>/dev/null || true; rm -rf -- "${dir}"; }
  trap cleanup EXIT
  if ((STATIC_PAGE)); then
    code="$(curl -q --proto '=https' --tlsv1.2 --noproxy '*' --silent --show-error \
      --connect-timeout 5 --max-time 15 --resolve "${DOMAIN}:443:127.0.0.1" \
      --output "${dir}/page" --write-out '%{http_code}' "https://${DOMAIN}/" 2>"${dir}/https.log")" || true
    [[ "${code}" == 200 ]] && grep -Fq '<body>asdfq</body>' "${dir}/page" || { warn "本机 HTTPS 静态页自测失败（HTTP ${code}）。"; cat "${dir}/https.log" >&2 || true; return 1; }
  fi
  client_port=$((22000 + RANDOM % 20000))
  cat >"${dir}/client.json" <<EOF
{
  "run_type":"client", "local_addr":"127.0.0.1", "local_port":${client_port},
  "remote_addr":"127.0.0.1", "remote_port":443, "password":["${PASSWORD}"], "log_level":1,
  "ssl":{"verify":true,"verify_hostname":true,"cert":"/etc/ssl/certs/ca-certificates.crt","sni":"${DOMAIN}","alpn":["http/1.1"],"reuse_session":true,"session_ticket":false},
  "tcp":{"prefer_ipv4":true,"no_delay":true,"keep_alive":true}
}
EOF
  "${BINARY}" -c "${dir}/client.json" >"${dir}/client.log" 2>&1 & client_pid=$!
  for ((i=0; i<15; i++)); do
    ss -H -ltn 2>/dev/null | awk -v p=":${client_port}" '$4 ~ (p "$" ) || $5 ~ (p "$" ) {ok=1} END{exit !ok}' && break
    kill -0 "${client_pid}" 2>/dev/null || break
    sleep 1
  done
  ss -H -ltn 2>/dev/null | awk -v p=":${client_port}" '$4 ~ (p "$" ) || $5 ~ (p "$" ) {ok=1} END{exit !ok}' || { warn "本机 Trojan 客户端未就绪。"; cat "${dir}/client.log" >&2; return 1; }
  code="$(curl -q --proto '=https' --tlsv1.2 --noproxy '' --socks5-hostname "127.0.0.1:${client_port}" \
    --silent --show-error --connect-timeout 5 --max-time 20 --retry 1 --retry-delay 1 --retry-max-time 31 \
    --output /dev/null --write-out '%{http_code}' https://www.google.com/generate_204 2>"${dir}/proxy.log")" || { warn "本机 Trojan 代理出站自测失败。"; cat "${dir}/proxy.log" >&2; cat "${dir}/client.log" >&2; return 1; }
  [[ "${code}" == 204 ]] || { warn "本机代理自测返回 HTTP ${code}，预期 204。"; return 1; }
  info "本机 Trojan TLS、认证、SOCKS 和 Google HTTP 204 自测通过。"
)

print_connection() {
  local encoded uri out="/root/trojan-${DOMAIN}.txt" png="/root/trojan-${DOMAIN}.png"
  encoded="$(python3 - "${PASSWORD}" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=''))
PY
)"
  uri="trojan://${encoded}@${DOMAIN}:443?peer=${DOMAIN}&allowInsecure=0#trojan"
  printf 'Trojan\nDomain: %s\nPort: 443 (TCP)\nPassword: %s\nSNI/Peer: %s\nURI: %s\n' "${DOMAIN}" "${PASSWORD}" "${DOMAIN}" "${uri}" >"${out}"
  chmod 0600 "${out}"
  info ""
  info "Trojan 安装、本机 HTTPS 页面和代理自测通过。"
  warn "公网客户端连通性仍需在 Shadowrocket 中实际验证。"
  info "域名: ${DOMAIN}"
  info "端口: 443（TCP/TLS）"
  ((STATIC_PAGE)) && info "静态页: https://${DOMAIN}/"
  info "密码: ${PASSWORD}"
  info "SNI/Peer: ${DOMAIN}"
  info "Shadowrocket URI（可手动导入）："
  info "${uri}"
  if command -v qrencode >/dev/null 2>&1 && printf '%s' "${uri}" | qrencode -o "${png}" -m 1 -s 4; then
    chmod 0600 "${png}"
    info "二维码 PNG 已保存：${png}（权限 600）"
    info "请放大下方终端二维码，用 Shadowrocket 扫描："
    printf '%s' "${uri}" | qrencode -t UTF8 -m 1 || warn "终端二维码显示失败；PNG 和 URI 仍已保存。"
  else
    warn "二维码生成失败；URI 已保存到 ${out}。"
  fi
}

install_trojan() {
  require_root; check_platform
  info "安装器版本：${SCRIPT_VERSION}（Trojan-GFW v${TROJAN_VERSION}）"
  collect_identity
  install_prerequisites
  require_command curl; require_command openssl; require_command lego; require_command python3; require_command ss; require_command systemctl
  LEGO_BIN="$(command -v lego)"
  validate_inputs
  getent ahostsv4 "${DOMAIN}" >/dev/null 2>&1 || die "当前 VM 无法解析 ${DOMAIN}；请先配置 A 记录并等待 DNS 生效。"
  if getent ahostsv6 "${DOMAIN}" >/dev/null 2>&1; then
    die "${DOMAIN} 存在 AAAA 记录，但此安装器只监听 IPv4；请删除错误 AAAA 或先配置可用 IPv6。"
  fi
  confirm_existing
  if [[ ! -e "${CONFIG_FILE}" && ! -e "${BINARY}" && \
        ! -e "/etc/systemd/system/${SERVICE}" && \
        ! -e "/etc/systemd/system/${FALLBACK_SERVICE}" && \
        ! -e "${STATE_FILE}" ]]; then
    FRESH_INSTALL=1
  fi
  backup_existing
  PREV_SERVICE_ACTIVE=0; PREV_FALLBACK_ACTIVE=0; NEW_SERVICES_STARTED=0
  systemctl is-active --quiet "${SERVICE}" 2>/dev/null && PREV_SERVICE_ACTIVE=1 || true
  systemctl is-active --quiet "${FALLBACK_SERVICE}" 2>/dev/null && PREV_FALLBACK_ACTIVE=1 || true
  INSTALL_RESTORE=1
  trap restore_previous_install EXIT
  USER_PREEXISTED=1; BINARY_PREEXISTED=1
  if id trojan >/dev/null 2>&1; then
    USER_PREEXISTED=1
  else
    USER_PREEXISTED=0
    USER_CREATED=1
    useradd --system --home-dir "${HOME_DIR}" --create-home --shell /usr/sbin/nologin trojan
  fi
  if systemctl is-active --quiet "${SERVICE}" 2>/dev/null; then systemctl stop "${SERVICE}"; fi
  if systemctl is-active --quiet "${FALLBACK_SERVICE}" 2>/dev/null; then systemctl stop "${FALLBACK_SERVICE}"; fi
  [[ -e "${BINARY}" ]] || BINARY_PREEXISTED=0
  if [[ -r "${STATE_FILE}" ]] && grep -qx 'bbr_created=1' "${STATE_FILE}"; then
    BBR_CREATED=1
    BBR_OLD_CC="$(sed -n 's/^bbr_old_cc=//p' "${STATE_FILE}" | head -n1)"
    BBR_OLD_QDISC="$(sed -n 's/^bbr_old_qdisc=//p' "${STATE_FILE}" | head -n1)"
  fi
  write_state
  if ss -H -ltnp 2>/dev/null | awk '$1=="LISTEN" && ($4 ~ /:443$/ || $5 ~ /:443$/) {found=1} END{exit !found}'; then
    die "TCP 443 已被其他进程占用；请先检查 ss -ltnp 并释放端口。"
  fi
  if ss -H -ltnp 2>/dev/null | awk '$1=="LISTEN" && ($4 ~ /:18080$/ || $5 ~ /:18080$/) {found=1} END{exit !found}'; then
    die "本机回落端口 18080 已被其他进程占用；请先检查 ss -ltnp 并释放端口。"
  fi
  download_binary
  configure_bbr
  install -d -m 0700 "${STATE_DIR}"
  write_state
  write_static_page
  write_fallback_service
  NEW_SERVICES_STARTED=1
  obtain_certificate
  sync_certificate
  write_config
  config_test || die "Trojan 配置检查失败；未生成连接信息。"
  write_service
  write_renewal_service
  systemctl start "${FALLBACK_SERVICE}"
  systemctl start "${SERVICE}" || { service_diagnostics; die "Trojan 服务启动失败；未生成连接信息。"; }
  sleep 1
  if ! systemctl is-active --quiet "${SERVICE}" || ! port_ready; then service_diagnostics; systemctl stop "${SERVICE}" || true; die "Trojan 未稳定监听 TCP 443；未生成连接信息。"; fi
  if ! local_selftest; then die "本机 Trojan 功能自测未通过；服务和配置已保留，未生成连接信息。"; fi
  write_state
  systemctl enable --now "${RENEW_TIMER}" >/dev/null
  INSTALL_RESTORE=0
  trap - EXIT
  print_connection
}

update_trojan() {
  require_root; check_platform
  [[ -x "${BINARY}" && -s "${CONFIG_FILE}" ]] || die "未找到已安装的 Trojan 程序和配置；请先执行 install。"
  backup_existing
  download_binary
  if ! config_test; then
    [[ -s "${BINARY_BACKUP}" ]] && cp -p "${BINARY_BACKUP}" "${BINARY}"
    die "更新后配置检查失败，服务未重启。"
  fi
  if systemctl is-active --quiet "${SERVICE}"; then
    if ! systemctl restart "${SERVICE}"; then
      [[ -s "${BINARY_BACKUP}" ]] && cp -p "${BINARY_BACKUP}" "${BINARY}"
      systemctl restart "${SERVICE}" || true
      die "更新后 Trojan 无法启动，已尝试恢复旧二进制。"
    fi
    sleep 1
    if ! systemctl is-active --quiet "${SERVICE}" || ! port_ready; then
      [[ -s "${BINARY_BACKUP}" ]] && cp -p "${BINARY_BACKUP}" "${BINARY}"
      systemctl restart "${SERVICE}" || true
      die "更新后 Trojan 未稳定监听 TCP 443，已尝试恢复旧二进制。"
    fi
    info "更新完成；已保留现有配置和密码，请使用现有客户端验证。"
  else
    info "更新完成；服务原先处于停止状态，未自动启动。"
  fi
}

uninstall_trojan() {
  require_root
  if (( ! YES )); then local answer; read -r -p "这会停止并删除 Trojan 服务，继续？[y/N] " answer || die "已取消。"; [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消。"; fi
  local user_preexisted=1 binary_preexisted=1 bbr_created=0 bbr_old_cc="" bbr_old_qdisc="" binary_backup=""
  [[ -r "${STATE_FILE}" ]] && grep -qx 'user_preexisted=0' "${STATE_FILE}" && user_preexisted=0
  [[ -r "${STATE_FILE}" ]] && grep -qx 'binary_preexisted=0' "${STATE_FILE}" && binary_preexisted=0
  [[ -r "${STATE_FILE}" ]] && grep -qx 'bbr_created=1' "${STATE_FILE}" && bbr_created=1
  if [[ -r "${STATE_FILE}" ]]; then
    bbr_old_cc="$(sed -n 's/^bbr_old_cc=//p' "${STATE_FILE}" | head -n1)"
    bbr_old_qdisc="$(sed -n 's/^bbr_old_qdisc=//p' "${STATE_FILE}" | head -n1)"
    binary_backup="$(sed -n 's/^binary_backup=//p' "${STATE_FILE}" | head -n1)"
  fi
  systemctl disable --now "${SERVICE}" >/dev/null 2>&1 || true
  systemctl disable --now "${FALLBACK_SERVICE}" >/dev/null 2>&1 || true
  systemctl disable --now "${RENEW_TIMER}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE}" "/etc/systemd/system/${FALLBACK_SERVICE}" \
    "/etc/systemd/system/${RENEW_SERVICE}" "/etc/systemd/system/${RENEW_TIMER}" "${RENEW_SCRIPT}"
  systemctl daemon-reload
  rm -f "${CONFIG_FILE}" "${CERT_FILE}" "${KEY_FILE}"
  if [[ -r "${STATE_FILE}" ]] && grep -Eq '^state_version=[12]$' "${STATE_FILE}"; then
    rm -rf -- "${STATIC_DIR}" "${LEGO_DIR}"
    if ((user_preexisted == 0)); then userdel trojan >/dev/null 2>&1 || true; fi
  fi
  [[ -d "${CONFIG_DIR}" ]] && rmdir "${CONFIG_DIR}" 2>/dev/null || true
  rm -rf -- "${STATE_DIR}"
  if ((binary_preexisted == 0)); then
    rm -f "${BINARY}"
  elif [[ -s "${binary_backup}" ]]; then
    cp -p "${binary_backup}" "${BINARY}"
  fi
  if ((bbr_created)); then
    [[ -z "${bbr_old_cc}" ]] || sysctl -w "net.ipv4.tcp_congestion_control=${bbr_old_cc}" >/dev/null 2>&1 || true
    [[ -z "${bbr_old_qdisc}" ]] || sysctl -w "net.core.default_qdisc=${bbr_old_qdisc}" >/dev/null 2>&1 || true
    rm -f /etc/sysctl.d/99-trojan-installer-bbr.conf
  fi
  info "Trojan 已卸载；连接二维码、配置备份、依赖包和云端 DNS/防火墙规则仍保留。安装器管理的 lego 证书账户已删除。"
}

service_action() { require_root; systemctl "${ACTION}" "${SERVICE}"; }

main() {
  parse_args "$@"
  case "${ACTION}" in
    install) install_trojan ;;
    update) update_trojan ;;
    uninstall) uninstall_trojan ;;
    start|stop|restart|status) service_action ;;
    *) die "不支持的操作：${ACTION}" ;;
  esac
}

main "$@"
