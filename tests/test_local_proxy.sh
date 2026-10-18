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
  for pid in "${client_pid}" "${server_pid}" "${backend_pid}"; do
    [[ -z "${pid}" ]] || wait "${pid}" 2>/dev/null || true
  done
  rm -rf -- "${work}"
}
trap cleanup EXIT

server_port=${TEST_SERVER_PORT:-$((24000 + RANDOM % 1000))}
client_port=$((25000 + RANDOM % 1000))
backend_port=$((26000 + RANDOM % 1000))
domain=trojan-installer.test
password=TestPassword16
mkdir -p "${work}/page"
printf 'asdfq\n' >"${work}/page/index.html"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=Test CA' \
  -keyout "${work}/ca.key" -out "${work}/ca.pem" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj "/CN=${domain}" \
  -keyout "${work}/key.pem" -out "${work}/server.csr" >/dev/null 2>&1
printf 'subjectAltName=DNS:%s\n' "${domain}" >"${work}/extensions"
openssl x509 -req -in "${work}/server.csr" -CA "${work}/ca.pem" -CAkey "${work}/ca.key" \
  -set_serial 1 -days 1 -extfile "${work}/extensions" -out "${work}/cert.pem" >/dev/null 2>&1

python3 -m http.server "${backend_port}" --bind 127.0.0.1 --directory "${work}/page" >"${work}/backend.log" 2>&1 &
backend_pid=$!
# Use the actual installer config, changing only local fixture paths and binding.
(
  source "$(dirname "${BASH_SOURCE[0]}")/../install.sh"
  PORT="${server_port}"; PASSWORD="${password}"
  render_config
) | python3 -c '
import json, sys
c=json.load(sys.stdin)
c["local_addr"]="127.0.0.1"
c["remote_port"]=int(sys.argv[2])
c["ssl"]["cert"]=sys.argv[1]+"/cert.pem"
c["ssl"]["key"]=sys.argv[1]+"/key.pem"
json.dump(c,sys.stdout)
' "${work}" "${backend_port}" >"${work}/server.json"
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
  if curl -q --noproxy '*' --cacert "${work}/ca.pem" \
    --connect-timeout 2 --max-time 3 --resolve "${domain}:${server_port}:127.0.0.1" \
    "https://${domain}:${server_port}/" 2>/dev/null | grep -Fxq asdfq; then
    break
  fi
  sleep .2
done
curl -q --noproxy '*' --cacert "${work}/ca.pem" \
  --connect-timeout 2 --max-time 3 --resolve "${domain}:${server_port}:127.0.0.1" \
  "https://${domain}:${server_port}/" 2>/dev/null | grep -Fxq asdfq

cat >"${work}/client.json" <<EOF_CLIENT
{
  "run_type":"client", "local_addr":"127.0.0.1", "local_port":${client_port},
  "remote_addr":"127.0.0.1", "remote_port":${server_port}, "password":["${password}"],
  "log_level":1,
  "ssl":{"verify":true,"verify_hostname":true,"cert":"${work}/ca.pem","sni":"${domain}","alpn":["http/1.1"]},
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
python3 "$(dirname "${BASH_SOURCE[0]}")/test_hot_reload.py" \
  "${work}" "${domain}" "${server_port}" "${client_port}" "${server_pid}"
# A new authenticated connection also works after hot reload.
curl -q --noproxy '' --connect-timeout 2 --max-time 3 \
  --socks5-hostname "127.0.0.1:${client_port}" \
  "http://127.0.0.1:${backend_port}/" 2>/dev/null | grep -Fxq asdfq
printf '%s\n' "real Trojan config, TLS verification, fallback, SOCKS forwarding, hot reload on TCP ${server_port}: PASS"
