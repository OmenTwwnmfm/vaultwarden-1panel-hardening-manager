#!/usr/bin/env bash
# 断言 sshd -T 输出无论配置名是小写（OpenSSH 9.x 及更早）还是驼峰（OpenSSH 10.x）都能正确读取
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0
for style in lower camel; do
  if [[ $style == camel ]]; then
    body='Port 10098
ListenAddress 0.0.0.0:10098
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey,keyboard-interactive'
  else
    body='port 10098
listenaddress 0.0.0.0:10098
passwordauthentication no
pubkeyauthentication yes
authenticationmethods publickey,keyboard-interactive'
  fi
  printf '#!/usr/bin/env bash\ncat <<"EOF"\n%s\nEOF\n' "$body" >"$T/sshd"
  chmod +x "$T/sshd"
  out=$(SSHD_BIN="$T/sshd" VH_LOG=/dev/null bash -c 'source scripts/vh-common.sh
    printf "%s|%s|%s|%s\n" "$(sshd_get port)" "$(sshd_get passwordauthentication)" "$(sshd_get pubkeyauthentication)" "$(sshd_get authenticationmethods)"')
  [[ $out == "10098|no|yes|publickey,keyboard-interactive" ]] || { echo "FAIL $style：$out"; fail=1; }
done
((fail == 0)) && echo "PASS sshd-parse"
exit $fail
