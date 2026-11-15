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

note "starting runner"
"$runner" --jitconfig "$(cat "$cfg")"
note "job finished"
sudo -n shutdown -h now
