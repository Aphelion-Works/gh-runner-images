#!/usr/bin/env bash
# =============================================================================
# check-ci-tools.sh: the CI tool installer pins amd64 and arm64 builds.
# No network. CI_TOOLS_DRY_RUN prints the chosen files.
# =============================================================================
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$root/.github/scripts/install-ci-tools.sh"
fails=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/        /'
  fails=$((fails + 1))
}

expect() {  # <uname -sm> <expected output>
  local machine="$1" want="$2" out status
  status=0
  out=$(CI_TOOLS_UNAME="$machine" CI_TOOLS_DRY_RUN=1 "$script") || status=$?
  if [[ "$status" -ne 0 ]]; then
    fail "$machine selects its builds" "$out"
    return
  fi
  if [[ "$out" == "$want" ]]; then
    pass "$machine selects its builds"
  else
    fail "$machine selects its builds" "$out"
  fi
}

expect "Linux x86_64" "$(cat <<'EOF'
8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  actionlint_1.7.12_linux_amd64.tar.gz
c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507  hadolint-linux-x86_64
bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf  trivy_0.76.2_Linux-64bit.tar.gz
EOF
)"

expect "Linux aarch64" "$(cat <<'EOF'
325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6  actionlint_1.7.12_linux_arm64.tar.gz
f6198ef8090f404dbb771abfee086eb8c48ac177f30da7fd3510aca35b344b5d  hadolint-linux-arm64
ab9d51f86e6a5fb936f605faff6b593ac51bc378fff4d3e8b9d58358b9c367c3  trivy_0.76.2_Linux-ARM64.tar.gz
EOF
)"

status=0
out=$(CI_TOOLS_UNAME="Darwin arm64" CI_TOOLS_DRY_RUN=1 "$script" 2>&1) || status=$?
if [[ "$status" -ne 0 && "$out" == "this script installs Linux x86_64 and aarch64 builds only" ]]; then
  pass "other machines are refused"
else
  fail "other machines are refused" "$out"
fi

if [[ "$fails" -ne 0 ]]; then
  printf '%d check(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'CI tool pin check passed\n'
