#!/usr/bin/env bash
# The macOS guest logs in and starts the runner in that session. This runs
# the guest script against stand-ins. No VM, no network, no GitHub.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guest="$root/macos/start-runner.sh"
plist="$root/macos/io.gh-runners.guest.plist"
build="$root/scripts/build-macos-image.sh"
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  [[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/        /'
  fails=$((fails + 1))
}

bin=$tmp/bin
mkdir -p "$bin"
cat >"$bin/launchctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$LAUNCHCTL_LOG"
if [ "$1" = kickstart ]; then
  if [ "${LAUNCHCTL_MODE:-up}" = up ]; then
    touch "$KICKED"
  fi
  exit 0
fi
if [ "$1" = print ] && [ -f "$KICKED" ]; then
  printf '\tstate = running\n'
  exit 0
fi
exit 1
EOF
cat >"$bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$SUDO_LOG"
exit 0
EOF
cat >"$bin/run.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" > "$RUNNER_LOG"
printf '%s\n' "$2" >> "$RUNNER_LOG"
exit 0
EOF
cat >"$bin/pgrep" <<'EOF'
#!/bin/sh
if [ "${PGREP_SETUP:-}" = 1 ]; then
  exit 0
fi
exit 1
EOF
cat >"$bin/killall" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$KILLALL_LOG"
exit 0
EOF
chmod 0755 "$bin/launchctl" "$bin/sudo" "$bin/run.sh" "$bin/pgrep" "$bin/killall"

run_guest() {
  env -i \
    PATH="$bin:/usr/bin:/bin" \
    HOME="$tmp/home" \
    GH_RUNNERS_SHARE="$1" \
    GH_RUNNERS_RUNNER="$bin/run.sh" \
    GH_RUNNERS_WAIT_SECONDS="${2:-3}" \
    GH_RUNNERS_SKIP_SETUP="${4:-$tmp/no-such-skip}" \
    PGREP_SETUP="${5:-}" \
    LAUNCHCTL_LOG="$tmp/launchctl.log" \
    LAUNCHCTL_MODE="${3:-up}" \
    KICKED="$tmp/kicked" \
    SUDO_LOG="$tmp/sudo.log" \
    RUNNER_LOG="$tmp/runner.log" \
    KILLALL_LOG="$tmp/killall.log" \
    SKIP_LOG="$tmp/skip.log" \
    bash "$guest"
}

# The host shares a directory named gh-runners. The JIT file lives there.
prepare_share() {
  rm -rf "$tmp/share" "$tmp/launchctl.log" "$tmp/kicked" "$tmp/sudo.log" "$tmp/runner.log"
  mkdir -p "$tmp/share/gh-runners"
  printf 'jit-octo-user\n' >"$tmp/share/gh-runners/jitconfig"
}

prepare_share
status=0
out=$(run_guest "$tmp/share" 3 up 2>&1) || status=$?
if [[ $status -eq 0 ]]; then pass "runner starts once testmanagerd is up"; else fail "runner starts once testmanagerd is up" "$out"; fi
if [[ $(cat "$tmp/runner.log") == "$(printf '%s\n' --jitconfig jit-octo-user)" ]]; then
  pass "runner receives the JIT config"
else
  fail "runner receives the JIT config" "$(cat "$tmp/runner.log" 2>/dev/null || true)"
fi
if [[ $(cat "$tmp/sudo.log") == "-n shutdown -h now" ]]; then
  pass "guest halts after the job"
else
  fail "guest halts after the job" "$(cat "$tmp/sudo.log" 2>/dev/null || true)"
fi
if grep -q "kickstart gui/$(id -u)/com.apple.testmanagerd" "$tmp/launchctl.log"; then
  pass "kickstarts the GUI testmanagerd"
else
  fail "kickstarts the GUI testmanagerd" "$(cat "$tmp/launchctl.log")"
fi
if [[ $(cat "$tmp/share/gh-runners/guest-status") == "job finished" ]]; then
  pass "status records the job finishing"
else
  fail "status records the job finishing" "$(cat "$tmp/share/gh-runners/guest-status" 2>/dev/null || true)"
fi

prepare_share
rm -f "$tmp/killall.log" "$tmp/skip.log"
cat >"$tmp/skip-setup" <<'EOF'
#!/bin/sh
printf 'ran\n' >> "$SKIP_LOG"
exit 0
EOF
chmod 0755 "$tmp/skip-setup"
status=0
out=$(run_guest "$tmp/share" 3 up "$tmp/skip-setup" 1 2>&1) || status=$?
if [[ $status -eq 0 ]]; then pass "open Setup Assistant does not stop the job"; else fail "open Setup Assistant does not stop the job" "$out"; fi
if [[ $out == *"closing Setup Assistant"* ]]; then
  pass "guest records an open Setup Assistant"
else
  fail "guest records an open Setup Assistant" "$out"
fi
if grep -q '^Setup Assistant$' "$tmp/killall.log" 2>/dev/null; then
  pass "guest closes Setup Assistant"
else
  fail "guest closes Setup Assistant" "$(cat "$tmp/killall.log" 2>/dev/null || true)"
fi
if [[ $(cat "$tmp/skip.log" 2>/dev/null || true) == "ran" ]]; then
  pass "guest marks Setup Assistant seen before the job"
else
  fail "guest marks Setup Assistant seen before the job" "$(cat "$tmp/skip.log" 2>/dev/null || true)"
fi
if [[ $(cat "$tmp/share/gh-runners/guest-status") == "job finished" ]]; then
  pass "closing Setup Assistant still finishes the job"
else
  fail "closing Setup Assistant still finishes the job" "$(cat "$tmp/share/gh-runners/guest-status" 2>/dev/null || true)"
fi

prepare_share
status=0
out=$(run_guest "$tmp/share" 1 down 2>&1) || status=$?
if [[ $status -eq 1 ]]; then pass "missing testmanagerd exits 1"; else fail "missing testmanagerd exits 1" "$out"; fi
if [[ ! -f $tmp/runner.log ]]; then pass "missing testmanagerd does not start the runner"; else fail "missing testmanagerd does not start the runner"; fi
if [[ ! -f $tmp/sudo.log ]]; then pass "missing testmanagerd does not halt"; else fail "missing testmanagerd does not halt"; fi
if [[ $(cat "$tmp/share/gh-runners/guest-status") == "testmanagerd is not running" ]]; then
  pass "status names the missing testmanagerd"
else
  fail "status names the missing testmanagerd" "$(cat "$tmp/share/gh-runners/guest-status" 2>/dev/null || true)"
fi

rm -rf "$tmp/share" "$tmp/launchctl.log" "$tmp/kicked" "$tmp/sudo.log" "$tmp/runner.log"
mkdir -p "$tmp/share/gh-runners"
status=0
out=$(run_guest "$tmp/share" 1 up 2>&1) || status=$?
if [[ $status -eq 1 ]]; then pass "missing JIT config exits 1"; else fail "missing JIT config exits 1" "$out"; fi
if [[ ! -f $tmp/launchctl.log ]]; then pass "missing JIT config does not wait on testmanagerd"; else fail "missing JIT config does not wait on testmanagerd"; fi
if [[ $(cat "$tmp/share/gh-runners/guest-status") == "guest runner is not ready" ]]; then
  pass "status names the missing runner"
else
  fail "status names the missing runner" "$(cat "$tmp/share/gh-runners/guest-status" 2>/dev/null || true)"
fi

if ! grep -q 'sudo -u' "$guest"; then pass "runner stays in the login session"; else fail "runner stays in the login session"; fi

status=0
python3 - "$plist" <<'PY' || status=$?
import plistlib, sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
ok = (
    data.get("Label") == "io.gh-runners.guest"
    and data.get("LimitLoadToSessionType") == "Aqua"
    and data.get("RunAtLoad") is True
    and data.get("ProgramArguments") == ["/usr/local/lib/gh-runners/start-runner.sh"]
    and data.get("StandardErrorPath") == "/Users/lume/Library/Logs/gh-runners-guest.log"
)
sys.exit(0 if ok else 1)
PY
if [[ $status -eq 0 ]]; then pass "LaunchAgent loads in the Aqua session"; else fail "LaunchAgent loads in the Aqua session"; fi

if grep -q '/Users/lume/Library/LaunchAgents/io.gh-runners.guest.plist' "$build"; then
  pass "image installs the login agent"
else
  fail "image installs the login agent"
fi
if grep -q 'LaunchDaemons' "$build"; then fail "image does not install a boot daemon"; else pass "image does not install a boot daemon"; fi
if grep -q 'sysadminctl -autologin set -userName lume' "$build"; then pass "image turns on auto-login"; else fail "image turns on auto-login"; fi
if grep -q 'sysadminctl -screenLock off' "$build"; then pass "image turns off the screen lock"; else fail "image turns off the screen lock"; fi
if grep -q 'pmset -a sleep 0 displaysleep 0 disksleep 0' "$build"; then pass "image keeps the session awake"; else fail "image keeps the session awake"; fi
if grep -q '/usr/sbin/DevToolsSecurity -enable' "$build"; then pass "image enables developer tools"; else fail "image enables developer tools"; fi
if grep -q 'macos/enable-automation.sh' "$build" && grep -F -q '/enable-automation.sh"' "$build"; then
  pass "image allows UI automation without a password"
else
  fail "image allows UI automation without a password"
fi
if grep -E -q '^[[:space:]]*[^#[:space:]].*spctl --global-disable' "$build"; then
  fail "image does not stop for Gatekeeper's System Settings confirmation"
else
  pass "image does not stop for Gatekeeper's System Settings confirmation"
fi
if grep -q 'LSQuarantine -bool false' "$build"; then pass "image turns off the quarantine warning"; else fail "image turns off the quarantine warning"; fi
if grep -q 'AutomaticCheckEnabled -bool false' "$build"; then pass "image turns off software update checks"; else fail "image turns off software update checks"; fi
if grep -q 'com.apple.CrashReporter DialogType none' "$build"; then pass "image keeps crash reports out of a dialog"; else fail "image keeps crash reports out of a dialog"; fi
if grep -q 'macos/skip-setup-assistant.sh' "$build" \
  && grep -q '/usr/local/lib/gh-runners/skip-setup-assistant.sh' "$build" \
  && grep -F -q '/skip-setup-assistant.sh"' "$build"; then
  pass "image marks Setup Assistant seen"
else
  fail "image marks Setup Assistant seen"
fi

automation=$tmp/automation
mark=$tmp/automation-ready
cat >"$automation" <<'EOF'
#!/bin/sh
if [ "$1" = enable-automationmode-without-authentication ]; then
  printf "Enter the password for user 'lume': "
  IFS= read -r got || exit 1
  if [ "$got" = "$EXPECT_PASSWORD" ]; then
    printf 'succeeded.\n'
    : > "$EXPECT_MARK"
    exit 0
  fi
  printf 'Authentication failed\n'
  exit 1
fi
if [ -f "$EXPECT_MARK" ]; then
  printf 'Automation Mode is disabled.\nThis device DOES NOT REQUIRE user authentication to enable Automation Mode.\n'
  exit 0
fi
printf 'This device requires user authentication to enable Automation Mode.\n'
exit 1
EOF
chmod 0755 "$automation"
if EXPECT_PASSWORD='pa$$ word' EXPECT_MARK="$mark" \
  GH_RUNNERS_MACOS_PASSWORD='pa$$ word' \
  GH_RUNNERS_AUTOMATION_TOOL="$automation" \
  "$root/macos/enable-automation.sh" >/dev/null; then
  pass "automation setup answers the password prompt"
else
  fail "automation setup answers the password prompt"
fi
rm -f "$mark"
rejected=$tmp/automation-rejected
if EXPECT_PASSWORD='pa$$ word' EXPECT_MARK="$mark" \
  GH_RUNNERS_MACOS_PASSWORD='wrong' \
  GH_RUNNERS_AUTOMATION_TOOL="$automation" \
  "$root/macos/enable-automation.sh" >"$rejected" 2>&1; then
  fail "automation setup rejects a wrong password"
elif grep -q 'Authentication failed' "$rejected"; then
  pass "automation setup rejects a wrong password"
else
  fail "automation setup rejects a wrong password" "$(cat "$rejected")"
fi

setup_bin=$tmp/setup-bin
mkdir -p "$setup_bin" "$tmp/template/English.lproj/Library/Preferences"
cat >"$setup_bin/sudo" <<'EOF'
#!/bin/sh
if [ "$1" = "-n" ] && [ "$2" = "true" ]; then
  exit 0
fi
if [ "$1" = "-n" ]; then
  shift
  exec "$@"
fi
exit 1
EOF
cat >"$setup_bin/defaults" <<'EOF'
#!/bin/sh
printf 'defaults %s\n' "$*" >> "$SEQUENCE"
printf '%s\n' "$*" >> "$DEFAULTS_LOG"
exit 0
EOF
cat >"$setup_bin/strings" <<'EOF'
#!/bin/sh
printf '%s\n' noise DidSeeCloudSetup DidSeeIntelligence LastSeenBuddyBuildVersion LastSeenCloudProductVersion LastSeenIntelligenceProductVersion
EOF
cat >"$setup_bin/sw_vers" <<'EOF'
#!/bin/sh
case "$1" in
  -productVersion) printf '26.6.2\n' ;;
  -buildVersion) printf '25G83\n' ;;
  *) exit 1 ;;
esac
EOF
cat >"$setup_bin/killall" <<'EOF'
#!/bin/sh
printf 'killall %s\n' "$*" >> "$SEQUENCE"
printf '%s\n' "$*" >> "$KILLALL_LOG"
exit 0
EOF
chmod 0755 "$setup_bin/sudo" "$setup_bin/defaults" "$setup_bin/strings" "$setup_bin/sw_vers" "$setup_bin/killall"
assistant=$tmp/SetupAssistant
printf '#!/bin/sh\n' >"$assistant"
chmod 0755 "$assistant"
: >"$tmp/defaults.log"
: >"$tmp/setup-killall.log"
: >"$tmp/sequence"
run_skip() {
  env -i \
    PATH="$setup_bin:/usr/bin:/bin" \
    GH_RUNNERS_DEFAULTS="$setup_bin/defaults" \
    GH_RUNNERS_STRINGS="$setup_bin/strings" \
    GH_RUNNERS_SETUP_ASSISTANT="$1" \
    GH_RUNNERS_SETUP_SYSTEM="$tmp/system-setup" \
    GH_RUNNERS_USER_TEMPLATE="$tmp/template" \
    GH_RUNNERS_SETUP_DONE="$tmp/AppleSetupDone" \
    DEFAULTS_LOG="$tmp/defaults.log" \
    KILLALL_LOG="$tmp/setup-killall.log" \
    SEQUENCE="$tmp/sequence" \
    bash "$root/macos/skip-setup-assistant.sh"
}
status=0
out=$(run_skip "$assistant" 2>&1) || status=$?
wrote() { grep -F -q "$1" "$tmp/defaults.log"; }
if [[ $status -eq 0 ]] \
  && wrote "write com.apple.SetupAssistant DidSeeCloudSetup -bool true" \
  && wrote "write com.apple.SetupAssistant DidSeeIntelligence -bool true" \
  && wrote "write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string 25G83" \
  && wrote "write com.apple.SetupAssistant LastSeenCloudProductVersion -string 26.6.2" \
  && wrote "write com.apple.SetupAssistant LastSeenIntelligenceProductVersion -string 26.6.2" \
  && wrote "write $tmp/system-setup LastSeenBuddyBuildVersion -string 25G83" \
  && wrote "write $tmp/template/English.lproj/Library/Preferences/com.apple.SetupAssistant DidSeeCloudSetup -bool true" \
  && wrote "write com.apple.SetupAssistant MiniBuddyShouldLaunchToResumeSetup -bool false" \
  && wrote "write com.apple.SetupAssistant MiniBuddyLaunchReason -int 0" \
  && wrote "write com.apple.SetupAssistant LastPreLoginTasksPerformedBuild -string 25G83" \
  && wrote "write com.apple.SetupAssistant LastPreLoginTasksPerformedVersion -string 26.6.2" \
  && wrote "write com.apple.SetupAssistant SkipFirstLoginOptimization -bool true" \
  && wrote "write com.apple.SetupAssistant LastPrivacyBundleVersion -string 26.6.2" \
  && ! wrote "noise" \
  && [[ -f $tmp/AppleSetupDone ]] \
  && [[ $(head -n 1 "$tmp/sequence") == "killall Setup Assistant" ]] \
  && [[ $(tail -n 1 "$tmp/sequence") == "killall Setup Assistant" ]]; then
  pass "setup screens are marked seen for the user, the system, and new accounts"
else
  fail "setup screens are marked seen for the user, the system, and new accounts" "${out}$(printf '\n')$(cat "$tmp/defaults.log" 2>/dev/null || true)"
fi

: >"$tmp/defaults.log"
status=0
out=$(run_skip "$tmp/missing-assistant" 2>&1) || status=$?
if [[ $status -eq 0 ]] \
  && wrote "write com.apple.SetupAssistant LastSeenBuddyBuildVersion -string 25G83" \
  && wrote "write com.apple.SetupAssistant LastSeenCloudProductVersion -string 26.6.2" \
  && wrote "write com.apple.SetupAssistant MiniBuddyShouldLaunchToResumeSetup -bool false" \
  && ! wrote "DidSee"; then
  pass "setup screens stay marked seen when the assistant cannot be read"
else
  fail "setup screens stay marked seen when the assistant cannot be read" "${out}$(printf '\n')$(cat "$tmp/defaults.log" 2>/dev/null || true)"
fi

if [[ $fails -ne 0 ]]; then
  exit 1
fi
printf 'ok\n'
