#!/usr/bin/env bash
set -Euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

for script in run.sh scripts/*.sh scripts/lib/*.sh tests/*.sh; do
  bash -n "$script" || exit 1
done

result=0
for test_script in tests/test-*.sh; do
  printf '== %s\n' "$test_script"
  bash "$test_script" || result=1
done
exit "$result"
