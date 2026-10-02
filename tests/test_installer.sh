#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
bash -n install.sh
./install.sh --help >/dev/null
# Load pure validation functions without running main.
source <(sed '/^main "\$@"/d' install.sh)
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
printf '%s\n' 'syntax, help, identity normalization, password generation, and input rejection: PASS'
