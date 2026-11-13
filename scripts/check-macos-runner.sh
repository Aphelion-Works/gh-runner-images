#!/usr/bin/env bash
# =============================================================================
# check-macos-runner.sh: compare runner_version in scripts/build-macos-image.sh
# with the latest actions/runner release.
#
# The Linux images take that release on their own. The macOS images do not:
# the version is pinned, and a Mac has to rebuild them. Exit 0 when the pin
# matches. Exit 1 when it is behind. Exit 2 when the pin or the release
# cannot be read. Uses GITHUB_TOKEN if set (higher API rate limit).
# =============================================================================
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

pinned=$(awk -F= '$1=="runner_version" { print $2; exit }' "$root/scripts/build-macos-image.sh")
[[ $pinned =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'check-macos-runner: runner_version is missing or malformed\n' >&2
  exit 2
}

auth=()
[[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
# shellcheck disable=SC2086 # empty auth array must stay unquoted
body=$(curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" \
  ${auth[@]+"${auth[@]}"} \
  https://api.github.com/repos/actions/runner/releases/latest) \
  || {
    printf 'check-macos-runner: could not read the latest actions/runner release\n' >&2
    exit 2
  }
latest=$(printf '%s\n' "$body" | awk -F'"' '/"tag_name":/ { sub(/^v/, "", $4); print $4; exit }')
[[ $latest =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  printf 'check-macos-runner: could not read the latest actions/runner release\n' >&2
  exit 2
}

if [[ $pinned == "$latest" ]]; then
  printf 'macOS image runner %s matches the latest actions/runner release\n' "$pinned"
  exit 0
fi

printf 'macOS image runner %s is behind actions/runner %s\n' "$pinned" "$latest" >&2
printf 'Update runner_version and runner_sha in scripts/build-macos-image.sh, then rebuild macos-15 and macos-26 on a Mac.\n' >&2
exit 1
