#!/usr/bin/env bash
# =============================================================================
# install-ci-tools.sh: install the pinned tools CI uses, checking each download
# against its published SHA-256. Linux x86_64 and aarch64.
#
#   .ci-tools/bin    actionlint, hadolint, trivy   (added to GITHUB_PATH in Actions)
#   The OS provides shellcheck (installed with apt if missing).
# Dependabot doesn't track these pins: bump them here.
#
# CI_TOOLS_UNAME and CI_TOOLS_DRY_RUN=1 let tests select an architecture and
# print the pinned files without downloading them.
# =============================================================================
set -euo pipefail

ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256_AMD64="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
ACTIONLINT_SHA256_ARM64="325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6"
HADOLINT_VERSION="2.15.1"
HADOLINT_SHA256_AMD64="c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507"
HADOLINT_SHA256_ARM64="f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d"
TRIVY_VERSION="0.76.2"
TRIVY_SHA256_AMD64="bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf"
TRIVY_SHA256_ARM64="ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3"

case "${CI_TOOLS_UNAME:-$(uname -sm)}" in
  "Linux x86_64")
    actionlint_file="actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
    actionlint_sha="$ACTIONLINT_SHA256_AMD64"
    hadolint_file="hadolint-linux-x86_64"
    hadolint_sha="$HADOLINT_SHA256_AMD64"
    trivy_file="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
    trivy_sha="$TRIVY_SHA256_AMD64"
    ;;
  "Linux aarch64")
    actionlint_file="actionlint_${ACTIONLINT_VERSION}_linux_arm64.tar.gz"
    actionlint_sha="$ACTIONLINT_SHA256_ARM64"
    hadolint_file="hadolint-linux-arm64"
    hadolint_sha="$HADOLINT_SHA256_ARM64"
    trivy_file="trivy_${TRIVY_VERSION}_Linux-ARM64.tar.gz"
    trivy_sha="$TRIVY_SHA256_ARM64"
    ;;
  *)
    echo "this script installs Linux x86_64 and aarch64 builds only" >&2
    exit 1
    ;;
esac

if [[ "${CI_TOOLS_DRY_RUN:-}" == 1 ]]; then
  printf '%s  %s\n' "$actionlint_sha" "$actionlint_file"
  printf '%s  %s\n' "$hadolint_sha" "$hadolint_file"
  printf '%s  %s\n' "$trivy_sha" "$trivy_file"
  exit 0
fi

BIN="${CI_TOOLS_DIR:-$PWD/.ci-tools}/bin"
mkdir -p "$BIN"

fetch() {  # <url> <sha256> <output>
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum --check --quiet
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/${actionlint_file}" \
  "$actionlint_sha" "$tmp/actionlint.tar.gz"
tar -xzf "$tmp/actionlint.tar.gz" -C "$BIN" actionlint
fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/${hadolint_file}" \
  "$hadolint_sha" "$BIN/hadolint"
chmod +x "$BIN/hadolint"
fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${trivy_file}" \
  "$trivy_sha" "$tmp/trivy.tar.gz"
tar -xzf "$tmp/trivy.tar.gz" -C "$BIN" trivy

if ! command -v shellcheck >/dev/null || ! command -v expect >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq --no-install-recommends shellcheck expect >/dev/null
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$BIN" >>"$GITHUB_PATH"; fi
"$BIN/actionlint" -version | head -n 1
"$BIN/hadolint" --version
"$BIN/trivy" --version | head -n 1
shellcheck --version | sed -n 2p
