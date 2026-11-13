#!/usr/bin/env bash
# The macOS image build pins one Xcode archive for both guests and checks
# its SHA-256. This reads the script. It does not download Xcode.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${root}/scripts/build-macos-image.sh"
fails=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  fails=$((fails + 1))
}

value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$script"
}

version=$(value xcode_version)
file=$(value xcode_file)
url=$(value xcode_url)
sha=$(value xcode_sha)

if [[ $version == 26.3 ]]; then pass "Xcode pin is 26.3"; else fail "Xcode pin is 26.3 (got ${version})"; fi
if [[ $file == Xcode_26.3_Universal.xip ]]; then pass "archive name"; else fail "archive name (got ${file})"; fi
if [[ $url == https://download.developer.apple.com/Developer_Tools/Xcode_26.3/Xcode_26.3_Universal.xip ]]; then
  pass "archive URL"
else
  fail "archive URL"
fi
if [[ $sha =~ ^[0-9a-f]{64}$ ]]; then pass "SHA-256 is 64 hex characters"; else fail "SHA-256 is 64 hex characters"; fi
if grep -q 'xcode-select -s /Applications/Xcode.app' "$script"; then pass "selects Xcode.app"; else fail "selects Xcode.app"; fi
if grep -q 'xcodebuild -license accept' "$script"; then pass "accepts the license"; else fail "accepts the license"; fi
if grep -F -q 'Xcode archive does not match its published SHA-256' "$script"; then
  pass "checks the archive SHA-256"
else
  fail "checks the archive SHA-256"
fi

[[ $fails -eq 0 ]]
printf 'ok\n'
