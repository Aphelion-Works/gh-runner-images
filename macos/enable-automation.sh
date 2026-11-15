#!/bin/bash
# Lets XCTest turn on UI automation without someone typing the admin password.
# automationmodetool reads that password from its own terminal. A pipe is not
# a terminal, so expect answers it. Accessibility and AppleEvents are a
# separate privacy decision and are not granted here.
set -euo pipefail

password=${GH_RUNNERS_MACOS_PASSWORD:-}
tool=${GH_RUNNERS_AUTOMATION_TOOL:-/usr/bin/automationmodetool}
expect_bin=${GH_RUNNERS_EXPECT:-/usr/bin/expect}

if [[ -z $password ]]; then
  printf 'enable-automation: guest password is empty\n' >&2
  exit 1
fi
if [[ ! -x $tool ]]; then
  printf 'enable-automation: %s is missing\n' "$tool" >&2
  exit 1
fi
if [[ ! -x $expect_bin ]]; then
  printf 'enable-automation: %s is missing\n' "$expect_bin" >&2
  exit 1
fi

export GH_RUNNERS_MACOS_PASSWORD
export GH_RUNNERS_AUTOMATION_TOOL=$tool
"$expect_bin" <<'EOF'
set timeout 60
log_user 1
set password $env(GH_RUNNERS_MACOS_PASSWORD)
set tool $env(GH_RUNNERS_AUTOMATION_TOOL)
spawn $tool enable-automationmode-without-authentication
expect {
  -re "(?i)password" {
    send -- $password
    send -- "\r"
  }
  -re "succeeded" {
    exit 0
  }
  timeout {
    exit 1
  }
  eof {}
}
expect {
  -re "succeeded" { exit 0 }
  -re "(?i)failed" { exit 1 }
  timeout { exit 1 }
  eof {}
}
catch wait result
set code [lindex $result 3]
if {$code eq ""} {
  exit 1
}
exit $code
EOF

status=$("$tool")
printf '%s\n' "$status"
printf '%s\n' "$status" | grep -q 'DOES NOT REQUIRE'
