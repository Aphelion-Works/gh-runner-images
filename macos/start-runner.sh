#!/bin/bash
# Runs as the logged-in lume user, from the Aqua LaunchAgent. The host mounts
# the JIT config at /Volumes/My Shared Files/gh-runners/jitconfig. UI tests
# need testmanagerd, and macOS only starts that inside this session. One job,
# then the VM halts and the host deletes the clone.
set -euo pipefail

share=${GH_RUNNERS_SHARE:-/Volumes/My Shared Files}
if [[ -d ${share}/gh-runners ]]; then
  share="${share}/gh-runners"
fi
cfg="${share}/jitconfig"
status="${share}/guest-status"
runner=${GH_RUNNERS_RUNNER:-/Users/lume/actions-runner/run.sh}
tries=${GH_RUNNERS_WAIT_SECONDS:-90}
if [[ ! $tries =~ ^[1-9][0-9]*$ ]]; then
  tries=90
fi

note() {
  printf 'gh-runners: %s\n' "$*" >&2
  printf '%s\n' "$*" >"$status" 2>/dev/null || true
}

# The system copy is com.apple.testmanagerd.remote and does not serve UI
# tests. The one that does is the Aqua agent, and only its own state counts.
service_running() {
  launchctl print "$1" 2>/dev/null | grep -E -q '^[[:space:]]*state = running$'
}

note "waiting for the runner"
ready=0
for ((i = 0; i < tries; i++)); do
  if [[ -s $cfg && -x $runner ]]; then
    ready=1
    break
  fi
  sleep 1
done
if [[ $ready -ne 1 ]]; then
  note "guest runner is not ready"
  exit 1
fi

service="gui/$(id -u)/com.apple.testmanagerd"
note "waiting for testmanagerd"
ready=0
for ((i = 0; i < tries; i++)); do
  if service_running "$service"; then
    ready=1
    break
  fi
  launchctl kickstart "$service" >/dev/null 2>&1 || true
  if service_running "$service"; then
    ready=1
    break
  fi
  sleep 1
done
if [[ $ready -ne 1 ]]; then
  note "testmanagerd is not running"
  exit 1
fi

# Setup Assistant owns the screen when it is open, so XCTest leaves the app
# under test in the background. macOS can open it after the runner has
# started, and again after it has been closed. Mark the screens seen, then
# keep closing it until the job ends.
skip=${GH_RUNNERS_SKIP_SETUP:-/usr/local/lib/gh-runners/skip-setup-assistant.sh}
interval=${GH_RUNNERS_SETUP_INTERVAL:-2}
if [[ ! $interval =~ ^[0-9]+$ ]]; then
  interval=2
fi
setup_open() {
  pgrep -x "Setup Assistant" >/dev/null 2>&1 && return 0
  pgrep -f "/Setup Assistant.app/" >/dev/null 2>&1
}
close_setup_assistant() {
  if setup_open; then
    note "closing Setup Assistant"
    killall "Setup Assistant" >/dev/null 2>&1 || true
  fi
}
watch_setup_assistant() {
  while true; do
    close_setup_assistant
    sleep "$interval"
  done
}
watcher=
stop_watcher() {
  if [[ -z ${watcher:-} ]]; then
    return 0
  fi
  local pid=$watcher
  watcher=
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
}
if [[ -x $skip ]]; then
  "$skip" || note "could not mark Setup Assistant seen"
  close_setup_assistant
  watch_setup_assistant &
  watcher=$!
  trap stop_watcher EXIT
fi
note "starting runner"
"$runner" --jitconfig "$(cat "$cfg")"
stop_watcher
trap - EXIT
note "job finished"
sudo -n shutdown -h now
