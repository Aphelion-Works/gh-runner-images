#!/usr/bin/env bash
# Stand-in for the runner's run.sh in tests: records who ran it, with what
# arguments, and the environment a job would inherit, into /out (a directory
# the test mounts).
set -euo pipefail
{
  echo "uid=$(id -u) groups=$(id -Gn)"
  printf 'arg=%s\n' "$@"
} >/out/run.txt
env | sort >/out/run-env.txt
