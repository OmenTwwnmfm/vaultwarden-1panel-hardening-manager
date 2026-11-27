#!/usr/bin/env bash
# 断言 VERSION 出现在 CHANGELOG 与 README 徽章；若当前提交有 tag 则与 VERSION 一致
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
v=$(tr -d '[:space:]' <VERSION)
grep -q "^## \[$v\]" CHANGELOG.md || { echo "FAIL CHANGELOG 缺少 $v"; exit 1; }
grep -Fq "badge/version-$v-" README.md || { echo "FAIL README 版本徽章不是 $v"; exit 1; }
tag=$(git describe --tags --exact-match 2>/dev/null || true)
[[ -z $tag || $tag == "v$v" ]] || { echo "FAIL tag $tag != v$v"; exit 1; }
echo "PASS release-policy ($v)"
