#!/usr/bin/env bash
# =============================================================================
# install-ci-tools.sh: install the pinned tools CI uses, checking each download
# against its published SHA-256. Linux x86_64 only.
#
#   .ci-tools/bin    actionlint, hadolint, trivy   (added to GITHUB_PATH in Actions)
#   The OS provides shellcheck (installed with apt if missing).
# Dependabot doesn't track these pins: bump them here.
# =============================================================================
set -euo pipefail

ACTIONLINT_VERSION="1.7.12"
ACTIONLINT_SHA256="8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"
HADOLINT_VERSION="2.15.1"
HADOLINT_SHA256="c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507"
TRIVY_VERSION="0.76.2"
TRIVY_SHA256="bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf"

[[ "$(uname -sm)" == "Linux x86_64" ]] || { echo "this script installs Linux x86_64 builds only" >&2; exit 1; }
BIN="${CI_TOOLS_DIR:-$PWD/.ci-tools}/bin"
mkdir -p "$BIN"

fetch() {  # <url> <sha256> <output>
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum --check --quiet
}

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
  "$ACTIONLINT_SHA256" "$tmp/actionlint.tar.gz"
tar -xzf "$tmp/actionlint.tar.gz" -C "$BIN" actionlint
fetch "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64" \
  "$HADOLINT_SHA256" "$BIN/hadolint"
chmod +x "$BIN/hadolint"
fetch "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz" \
  "$TRIVY_SHA256" "$tmp/trivy.tar.gz"
tar -xzf "$tmp/trivy.tar.gz" -C "$BIN" trivy

if ! command -v shellcheck >/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq --no-install-recommends shellcheck >/dev/null
fi

if [[ -n "${GITHUB_PATH:-}" ]]; then echo "$BIN" >>"$GITHUB_PATH"; fi
"$BIN/actionlint" -version | head -n 1
"$BIN/hadolint" --version
"$BIN/trivy" --version | head -n 1
shellcheck --version | sed -n 2p
