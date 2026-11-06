#!/usr/bin/env bash
# =============================================================================
# resolve-versions.sh: print the build arguments for the newest releases, as
# KEY=value lines (for $GITHUB_OUTPUT, or `--build-arg` locally):
#
#   RUNNER_VERSION, RUNNER_SHA256_AMD64, RUNNER_SHA256_ARM64   actions/runner
#   YQ_VERSION, YQ_SHA256_AMD64, YQ_SHA256_ARM64               mikefarah/yq
#
# SHA-256s come from GitHub's own digest of each release asset. Set
# RUNNER_VERSION or YQ_VERSION (e.g. 2.338.2, v4.54.2) to pin a release instead
# of the latest. Uses GITHUB_TOKEN if set (higher API rate limit).
# =============================================================================
set -euo pipefail

api() {
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "https://api.github.com/$1"
}

release() {  # <owner/repo> <tag or empty for latest>
  if [[ -n "$2" ]]; then api "repos/$1/releases/tags/$2"; else api "repos/$1/releases/latest"; fi
}

sha() {  # <release json> <asset name>
  local d
  d="$(jq -er --arg n "$2" '.assets[] | select(.name == $n) | .digest' <<<"$1")" \
    || { echo "asset $2 not found" >&2; return 1; }
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "asset $2 has no SHA-256 digest" >&2; return 1; }
  echo "${d#sha256:}"
}

runner="$(release actions/runner "${RUNNER_VERSION:+v${RUNNER_VERSION#v}}")"
rv="$(jq -er '.tag_name' <<<"$runner")"; rv="${rv#v}"
echo "RUNNER_VERSION=${rv}"
echo "RUNNER_SHA256_AMD64=$(sha "$runner" "actions-runner-linux-x64-${rv}.tar.gz")"
echo "RUNNER_SHA256_ARM64=$(sha "$runner" "actions-runner-linux-arm64-${rv}.tar.gz")"

yq="$(release mikefarah/yq "${YQ_VERSION:-}")"
yv="$(jq -er '.tag_name' <<<"$yq")"
echo "YQ_VERSION=${yv}"
echo "YQ_SHA256_AMD64=$(sha "$yq" yq_linux_amd64)"
echo "YQ_SHA256_ARM64=$(sha "$yq" yq_linux_arm64)"
