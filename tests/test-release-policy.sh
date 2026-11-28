#!/usr/bin/env bash
# 断言 VERSION、CHANGELOG、README 徽章与发布标签一致
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
version=$(<VERSION)
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo 'FAIL VERSION 必须是主版本.次版本.修订号'; exit 1; }
pattern=${version//./\\.}
grep -Eq "^## \[$pattern\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md || { echo "FAIL CHANGELOG 缺少 $version 的版本条目"; exit 1; }
grep -Eq "^!\[Version\]\(https://img\.shields\.io/badge/version-$pattern-[^)]+\)$" README.md || { echo "FAIL README 版本徽章不是 $version"; exit 1; }
tags=$(git tag --list 'v[0-9]*' --points-at HEAD) || exit 1
while IFS= read -r tag; do
  [[ -z $tag || $tag == "v$version" ]] || { echo "FAIL tag $tag != v$version"; exit 1; }
done <<<"$tags"
if [[ ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REF_NAME:-} != "v$version" ]]; then
  echo "FAIL 推送的标签 ${GITHUB_REF_NAME:-未知} != v$version"
  exit 1
fi
echo "PASS release-policy ($version)"
