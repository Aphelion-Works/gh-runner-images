#!/usr/bin/env bash
# =============================================================================
# check-macos-runner.sh: the version check, against a stand-in for curl.
# No network and no GitHub access. The stand-in prints CHECK_RUNNER_BODY.
# =============================================================================
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
check="$root/scripts/check-macos-runner.sh"
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pinned=$(awk -F= '$1=="runner_version" { print $2; exit }' "$root/scripts/build-macos-image.sh")

cat >"$tmp/curl" <<'EOF'
#!/bin/sh
status=${CHECK_RUNNER_CURL_STATUS:-0}
if [ "$status" -ne 0 ]; then
  exit "$status"
fi
printf '%s\n' "$CHECK_RUNNER_BODY"
EOF
chmod 0755 "$tmp/curl"

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/        /'
  fails=$((fails + 1))
}

status=0
out=

capture() {
  status=0
  out=$(PATH="$tmp:$PATH" "$@" "$check" 2>&1) || status=$?
}

release() { # <version>
  printf '{\n  "tag_name": "v%s"\n}\n' "$1"
}

capture env CHECK_RUNNER_BODY="$(release "$pinned")"
if [[ $status -eq 0 ]]; then pass "matching release exits 0"; else fail "matching release exits 0" "$out"; fi
if [[ $out == "macOS image runner ${pinned} matches the latest actions/runner release" ]]; then
  pass "matching release names the pin"
else
  fail "matching release names the pin" "$out"
fi

capture env CHECK_RUNNER_BODY="$(release 9.9.9)"
if [[ $status -eq 1 ]]; then pass "older pin exits 1"; else fail "older pin exits 1" "$out"; fi
behind="macOS image runner ${pinned} is behind actions/runner 9.9.9
Update runner_version and runner_sha in scripts/build-macos-image.sh, then rebuild macos-15 and macos-26 on a Mac."
if [[ $out == "$behind" ]]; then pass "older pin names both versions"; else fail "older pin names both versions" "$out"; fi

capture env CHECK_RUNNER_BODY='{"tag_name":"nope"}'
if [[ $status -eq 2 ]]; then pass "malformed release exits 2"; else fail "malformed release exits 2" "$out"; fi

capture env CHECK_RUNNER_CURL_STATUS=22 CHECK_RUNNER_BODY=
if [[ $status -eq 2 ]]; then pass "release request failure exits 2"; else fail "release request failure exits 2" "$out"; fi

[[ $fails -eq 0 ]]
printf 'ok\n'
