#!/usr/bin/env bash
# The macOS image build pins one Xcode archive per guest and checks its
# SHA-256. This reads the script. It does not download Xcode.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${root}/scripts/build-macos-image.sh"
fails=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

# arm prints one assignment from a case arm. The two guests pin different
# Xcode releases, so the first assignment in the file is not enough.
arm() {
  awk -F= -v tag="$1)" -v key="$2" '
    $0 ~ "^[[:space:]]*" tag "$" { on = 1; next }
    on && $0 ~ "^[[:space:]]*\\*\\)" { exit }
    on && $1 ~ "^[[:space:]]*" key "$" { print substr($0, index($0, "=") + 1); exit }
  ' "$script"
}

check_pin() {
  local tag=$1 version=$2 file=$3 url=$4
  local got_version got_file got_url got_sha
  got_version=$(arm "$tag" xcode_version)
  got_file=$(arm "$tag" xcode_file)
  got_url=$(arm "$tag" xcode_url)
  got_sha=$(arm "$tag" xcode_sha)
  if [[ $got_version == "$version" ]]; then pass "${tag} Xcode pin is ${version}"; else fail "${tag} Xcode pin is ${version} (got ${got_version})"; fi
  if [[ $got_file == "$file" ]]; then pass "${tag} archive name"; else fail "${tag} archive name (got ${got_file})"; fi
  if [[ $got_url == "$url" ]]; then pass "${tag} archive URL"; else fail "${tag} archive URL"; fi
  if [[ $got_sha =~ ^[0-9a-f]{64}$ ]]; then pass "${tag} SHA-256 is 64 hex characters"; else fail "${tag} SHA-256 is 64 hex characters"; fi
}

check_pin macos-15 26.3 Xcode_26.3_Universal.xip \
  https://download.developer.apple.com/Developer_Tools/Xcode_26.3/Xcode_26.3_Universal.xip
check_pin macos-26 27.2 Xcode_27.2_Universal.xip \
  https://download.developer.apple.com/Developer_Tools/Xcode_27.2/Xcode_27.2_Universal.xip

if grep -q 'xcode-select -s /Applications/Xcode.app' "$script"; then pass "selects Xcode.app"; else fail "selects Xcode.app"; fi
if grep -q 'xcodebuild -license accept' "$script"; then pass "accepts the license"; else fail "accepts the license"; fi
if grep -F -q 'Xcode archive does not match its published SHA-256' "$script"; then
  pass "checks the archive SHA-256"
else
  fail "checks the archive SHA-256"
fi

[[ $fails -eq 0 ]]
printf 'ok\n'
