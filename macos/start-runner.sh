#!/bin/bash
# Boots inside a lume macOS guest. The host mounts the JIT config at
# /Volumes/My Shared Files/jitconfig. One job, then the VM halts and the
# host deletes the clone.
set -euo pipefail

share="/Volumes/My Shared Files"
if [[ -d ${share}/gh-runners ]]; then
  share="${share}/gh-runners"
fi
cfg="${share}/jitconfig"
runner="/Users/lume/actions-runner/run.sh"

for ((i = 0; i < 90; i++)); do
  if [[ -s $cfg && -x $runner ]]; then
    break
  fi
  sleep 1
done
if [[ ! -s $cfg || ! -x $runner ]]; then
  printf 'gh-runners: guest runner is not ready\n' >&2
  exit 1
fi

sudo -u lume "$runner" --jitconfig "$(cat "$cfg")"
shutdown -h now
