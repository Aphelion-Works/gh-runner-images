#!/usr/bin/env bash
# =============================================================================
# build.sh <image> [docker build args...]: build one image locally.
#
#   <image> is one of the published names: ubuntu-24.04, ubuntu-24.04-tools,
#   ubuntu-26.04 (any ubuntu-<version>[-tools] works). The result is tagged
#   gh-runner-images:<image>. CI builds the same way through the workflow.
#
#   scripts/build.sh ubuntu-24.04-tools --platform linux/amd64
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

image="${1:?usage: scripts/build.sh <ubuntu-XX.YY[-tools]> [docker build args...]}"; shift
[[ "$image" =~ ^ubuntu-([0-9]{2}\.[0-9]{2})(-tools)?$ ]] \
  || { echo "image must look like ubuntu-24.04 or ubuntu-24.04-tools" >&2; exit 1; }
ubuntu="${BASH_REMATCH[1]}"
variant=base; [[ -n "${BASH_REMATCH[2]}" ]] && variant=tools

args=(--build-arg "UBUNTU_VERSION=${ubuntu}" --build-arg "VARIANT=${variant}"
  --build-arg "IMAGE_OS=ubuntu${ubuntu%%.*}")
while IFS= read -r kv; do args+=(--build-arg "$kv"); done < <(scripts/resolve-versions.sh)

docker build "${args[@]}" -t "gh-runner-images:${image}" "$@" .
