#!/usr/bin/env bash
set -Eeuo pipefail

BIN="${TROJAN_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/trojan}"
command -v openssl >/dev/null || { echo 'openssl is required' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'python3 is required' >&2; exit 2; }
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 2; }
command -v ss >/dev/null || { echo 'iproute2/ss is required' >&2; exit 2; }
[[ -x "${BIN}" ]] || { echo "set TROJAN_BIN to a Trojan-GFW v1.16.0 binary" >&2; exit 2; }

work="$(mktemp -d /tmp/trojan-installer-test.XXXXXXXX)"
server_pid=""
client_pid=""
backend_pid=""
cleanup() {
  [[ -z "${client_pid}" ]] || kill "${client_pid}" 2>/dev/null || true
  [[ -z "${server_pid}" ]] || kill "${server_pid}" 2>/dev/null || true
  [[ -z "${backend_pid}" ]] || kill "${backend_pid}" 2>/dev/null || true
  rm -rf -- "${work}"
}
trap cleanup EXIT

server_port=$((24000 + RANDOM % 1000))
client_port=$((25000 + RANDOM % 1000))
backend_port=$((26000 + RANDOM % 1000))
domain=trojan-installer.test
password=TestPassword16
mkdir -p "${work}/page"
printf 'asdfq\n' >"${work}/page/index.html"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" \
  -keyout "${work}/key.pem" -out "${work}/cert.pem" >/dev/null 2>&1

python3 -m http.server "${backend_port}" --bind 127.0.0.1 --directory "${work}/page" >"${work}/backend.log" 2>&1 &
backend_pid=$!
cat >"${work}/server.json" <<EOF_SERVER
{
  "run_type":"server", "local_addr":"127.0.0.1", "local_port":${server_port},
  "remote_addr":"127.0.0.1", "remote_port":${backend_port}, "password":["${password}"],
  "log_level":1,
  "ssl":{"cert":"${work}/cert.pem","key":"${work}/key.pem","alpn":["http/1.1"]},
  "tcp":{"prefer_ipv4":true,"no_delay":true,"keep_alive":true}
}
EOF_SERVER
"${BIN}" -t -c "${work}/server.json" >/dev/null
"${BIN}" -c "${work}/server.json" >"${work}/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 1 20); do
  ss -H -ltn "sport = :${server_port}" | grep -q . && break
  kill -0 "${server_pid}" 2>/dev/null || { cat "${work}/server.log" >&2; exit 1; }
  sleep .2
done
ss -H -ltn "sport = :${server_port}" | grep -q .
for _ in $(seq 1 20); do
  if curl -q --noproxy '*' --cacert "${work}/cert.pem" \
    --connect-timeout 2 --max-time 3 --resolve "${domain}:${server_port}:127.0.0.1" \
    "https://${domain}:${server_port}/" 2>/dev/null | grep -Fxq asdfq; then
    break
  fi
  sleep .2
done
curl -q --noproxy '*' --cacert "${work}/cert.pem" \
  --connect-timeout 2 --max-time 3 --resolve "${domain}:${server_port}:127.0.0.1" \
  "https://${domain}:${server_port}/" 2>/dev/null | grep -Fxq asdfq

cat >"${work}/client.json" <<EOF_CLIENT
{
  "run_type":"client", "local_addr":"127.0.0.1", "local_port":${client_port},
  "remote_addr":"127.0.0.1", "remote_port":${server_port}, "password":["${password}"],
  "log_level":1,
  "ssl":{"verify":true,"verify_hostname":true,"cert":"${work}/cert.pem","sni":"${domain}","alpn":["http/1.1"]},
  "tcp":{"prefer_ipv4":true,"no_delay":true,"keep_alive":true}
}
EOF_CLIENT
"${BIN}" -t -c "${work}/client.json" >/dev/null
"${BIN}" -c "${work}/client.json" >"${work}/client.log" 2>&1 &
client_pid=$!
for _ in $(seq 1 20); do
  ss -H -ltn "sport = :${client_port}" | grep -q . && break
  kill -0 "${client_pid}" 2>/dev/null || { cat "${work}/client.log" >&2; exit 1; }
  sleep .2
done
ss -H -ltn "sport = :${client_port}" | grep -q .
for _ in $(seq 1 20); do
  if curl -q --noproxy '' --connect-timeout 2 --max-time 3 \
    --socks5-hostname "127.0.0.1:${client_port}" \
    "http://127.0.0.1:${backend_port}/" 2>/dev/null | grep -Fxq asdfq; then
    break
  fi
  sleep .2
done
curl -q --noproxy '' --connect-timeout 2 --max-time 3 \
  --socks5-hostname "127.0.0.1:${client_port}" \
  "http://127.0.0.1:${backend_port}/" 2>/dev/null | grep -Fxq asdfq
printf '%s\n' 'local Trojan config, TLS fallback, authentication, and SOCKS forwarding: PASS'
