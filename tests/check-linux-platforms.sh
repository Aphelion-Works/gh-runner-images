#!/usr/bin/env bash
# =============================================================================
# check-linux-platforms.sh: the published Linux tags are built for amd64 and
# arm64, and a later job combines the two into one manifest list.
# No Docker and no network.
# =============================================================================
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wf="$root/.github/workflows/images.yml"
fails=0

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); }

for name in ubuntu-24.04 ubuntu-24.04-tools ubuntu-26.04; do
  for arch in amd64 arm64; do
    if grep -Eq "name: ${name}, .* arch: ${arch}," "$wf"; then
      pass "$name is built for $arch"
    else
      fail "$name is built for $arch"
    fi
  done
done

if grep -Eq '^  manifest:' "$wf"; then
  pass "manifest job publishes one tag for both architectures"
else
  fail "manifest job publishes one tag for both architectures"
fi

if grep -Eq 'platforms: linux/\$\{\{ matrix\.arch \}\}' "$wf"; then
  pass "each build uses its own architecture"
else
  fail "each build uses its own architecture"
fi

if grep -Eq 'platforms: linux/amd64$' "$wf"; then
  fail "a build is still pinned to linux/amd64"
else
  pass "no build is pinned to linux/amd64"
fi

if [ "$fails" -ne 0 ]; then
  printf '%d check(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'linux platform check passed\n'
