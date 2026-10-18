#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
bash -n install.sh
./install.sh --help >/dev/null
# Sourcing is side-effect free: main only runs when install.sh is executed.
source ./install.sh
[[ "${PORT}" == 443 && "${ENABLE_BBR}" == 1 ]]
DOMAIN='Example.COM'
EMAIL='admin@example.com'
PASSWORD=''
PASSWORD_FROM_STDIN=0
collect_identity
validate_inputs
[[ "${DOMAIN}" == example.com ]]
[[ "${PASSWORD}" =~ ^[A-Fa-f0-9]{16}$ ]]
DOMAIN='example.com'
EMAIL='admin@example.com'
PASSWORD='valid-password_16'
validate_inputs
if (DOMAIN='bad domain'; EMAIL='admin@example.com'; PASSWORD='valid-password_16'; validate_inputs) 2>/dev/null; then
  echo 'invalid domain was accepted' >&2
  exit 1
fi
parse_args install --port 8443 --no-bbr
validate_inputs
[[ "${PORT}" == 8443 && "${ENABLE_BBR}" == 0 ]]
render_config | python3 -c 'import json,sys; assert json.load(sys.stdin)["local_port"] == 8443'
[[ "$(connection_uri)" == 'trojan://valid-password_16@example.com:8443?peer=example.com&allowInsecure=0#trojan' ]]
work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT
printf '{"local_port":8443}\n' >"${work}/server.json"
PORT=443
load_installed_port "${work}/server.json"
[[ "${PORT}" == 8443 ]]
printf '{"local_port":"8443"}\n' >"${work}/server.json"
if (load_installed_port "${work}/server.json") 2>/dev/null; then
  echo 'invalid installed JSON port was accepted' >&2
  exit 1
fi
PORT=0443
validate_port
[[ "${PORT}" == 443 ]]
for invalid in 0 65536 -1 80 18080 abc '443;id' 1.5 99999999999999999999 ''; do
  if (PORT="${invalid}"; validate_port) 2>/dev/null; then
    echo "invalid port was accepted: ${invalid}" >&2
    exit 1
  fi
done
if (parse_args --port) 2>/dev/null; then
  echo 'missing port argument was accepted' >&2
  exit 1
fi
(
  PORT=8443
  systemctl() { printf '%s\n' "${test_pid}"; }
  ss() {
    [[ "$3" == 'sport = :8443' ]] || return 99
    printf '%s\n' 'LISTEN 0 1024 0.0.0.0:8443 0.0.0.0:* users:(("trojan",pid=4242,fd=6))'
  }
  test_pid=4242; port_ready
  test_pid=42; if port_ready; then echo 'wrong process accepted' >&2; exit 1; fi
  test_pid=0; if port_ready; then echo 'missing process accepted' >&2; exit 1; fi
)
printf '%s\n' 'syntax, defaults, inputs, custom-port config and Shadowrocket URI: PASS'
python3 tests/test_runtime.py
