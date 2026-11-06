#!/usr/bin/env bash
# =============================================================================
# install-base.sh: what every image needs. Runs once at image build, as root.
#   - the runner's OS dependencies (ICU, OpenSSL, Kerberos, zlib)
#   - Docker Engine from Docker's own apt repository (key fingerprint checked)
#   - tini as PID 1, sudo, git, curl, jq
#   - the `runner` user (uid 1001, as on GitHub's runners) with passwordless
#     sudo and access to the job's Docker daemon
# =============================================================================
set -euo pipefail

DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  ca-certificates curl git gnupg iptables jq lsb-release sudo tini tzdata unzip xz-utils zip

# --- runner dependencies: pick whatever versions this Ubuntu release ships ------
newest() {  # <regex>: newest package whose name matches
  apt-cache search --names-only "$1" | awk '{print $1}' | sort -V | tail -n 1
}
icu="$(newest '^libicu[0-9]+$')"
ssl="$(newest '^libssl3(t64)?$')"
lttng="$(newest '^liblttng-ust[0-9]+(t64)?$')"
[[ -n "$icu" && -n "$ssl" ]] || { echo "runner dependencies not found (icu='$icu' ssl='$ssl')" >&2; exit 1; }
# shellcheck disable=SC2086  # $lttng is optional and may be empty
apt-get install -y --no-install-recommends "$icu" "$ssl" libkrb5-3 zlib1g $lttng

# --- Docker Engine ------------------------------------------------------------------
# shellcheck source=/dev/null
. /etc/os-release
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/ubuntu/gpg" -o /etc/apt/keyrings/docker.asc
fpr="$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc | awk -F: '$1=="fpr"{print $10; exit}')"
[[ "$fpr" == "$DOCKER_KEY_FPR" ]] || { echo "Docker apt key fingerprint is '$fpr', expected $DOCKER_KEY_FPR" >&2; exit 1; }
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# --- users and directories ------------------------------------------------------------
# Ubuntu images ship an `ubuntu` user with uid 1000; GitHub's runner user is 1001.
groupadd --gid 1001 runner
useradd --uid 1001 --gid runner --create-home --shell /bin/bash runner
getent group docker >/dev/null || groupadd --system docker
usermod -aG sudo,docker runner
printf '%s\n' 'runner ALL=(ALL:ALL) NOPASSWD:ALL' 'Defaults env_keep += "DEBIAN_FRONTEND"' > /etc/sudoers.d/runner
chmod 0440 /etc/sudoers.d/runner
visudo -cf /etc/sudoers.d/runner >/dev/null

install -d -o runner -g runner /_work /opt/hostedtoolcache

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
