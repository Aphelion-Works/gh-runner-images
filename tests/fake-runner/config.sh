#!/usr/bin/env bash
# Stand-in for the runner's config.sh in tests: records who ran it, with what
# arguments and environment, into /out (a directory the test mounts).
set -euo pipefail
{
  echo "uid=$(id -u)"
  echo "cwd=$(pwd)"
  printf 'arg=%s\n' "$@"
} >/out/config.txt
env | sort >/out/config-env.txt
