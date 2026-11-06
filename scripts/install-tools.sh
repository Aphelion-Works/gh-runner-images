#!/usr/bin/env bash
# =============================================================================
# install-tools.sh: the `tools` variant. Common CI tools that GitHub's own
# Ubuntu runners have and a bare image lacks. Runs once at image build, as root.
# Needs TARGETARCH, YQ_VERSION and YQ_SHA256_AMD64 / YQ_SHA256_ARM64.
# =============================================================================
set -euo pipefail

GH_KEYRING_SHA256="6084d5d7bd8e288441e0e94fc6275570895da18e6751f70f057485dc2d1a811b"

# --- GitHub CLI repository (keyring checked against cli/cli's published SHA-256) --
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "${GH_KEYRING_SHA256}  /etc/apt/keyrings/githubcli-archive-keyring.gpg" | sha256sum --check --quiet
chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

apt-get update
apt-get install -y --no-install-recommends \
  build-essential pkg-config gettext file patch \
  zlib1g-dev libssl-dev libcurl4-openssl-dev libpq-dev libyaml-dev libffi-dev \
  python3 python3-dev python3-pip python3-venv python3-setuptools pipx \
  nodejs \
  shellcheck git-lfs gh \
  zstd bzip2 rsync wget openssh-client iputils-ping dnsutils netcat-openbsd

# --- yq (mikefarah), checked against the release's published SHA-256 -------------
case "${TARGETARCH:?TARGETARCH is required}" in
  amd64) sha="${YQ_SHA256_AMD64:-}" ;;
  arm64) sha="${YQ_SHA256_ARM64:-}" ;;
  *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac
: "${YQ_VERSION:?YQ_VERSION is required (see scripts/resolve-versions.sh)}"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "missing or malformed yq SHA-256 for $TARGETARCH" >&2; exit 1; }
curl -fsSL --retry 3 -o /usr/local/bin/yq \
  "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}"
echo "${sha}  /usr/local/bin/yq" | sha256sum --check --quiet
chmod 0755 /usr/local/bin/yq

git lfs install --system >/dev/null

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
