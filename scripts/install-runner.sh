#!/usr/bin/env bash
# =============================================================================
# install-runner.sh <dir>: download GitHub's official runner release into <dir>
# and check it against the SHA-256 published with the release.
# Needs RUNNER_VERSION, TARGETARCH and RUNNER_SHA256_AMD64 / RUNNER_SHA256_ARM64
# (scripts/resolve-versions.sh prints them).
# =============================================================================
set -euo pipefail

dest="${1:?usage: install-runner.sh <dir>}"
: "${RUNNER_VERSION:?RUNNER_VERSION is required (see scripts/resolve-versions.sh)}"

case "${TARGETARCH:?TARGETARCH is required}" in
  amd64) arch=x64;   sha="${RUNNER_SHA256_AMD64:-}" ;;
  arm64) arch=arm64; sha="${RUNNER_SHA256_ARM64:-}" ;;
  *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "missing or malformed runner SHA-256 for $TARGETARCH" >&2; exit 1; }

file="actions-runner-linux-${arch}-${RUNNER_VERSION}.tar.gz"
curl -fsSL --retry 3 -o "/tmp/$file" \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${file}"
echo "${sha}  /tmp/${file}" | sha256sum --check --quiet
mkdir -p "$dest"
tar -xzf "/tmp/$file" -C "$dest"
rm -f "/tmp/$file"
