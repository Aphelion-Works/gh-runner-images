#!/usr/bin/env bash
# Stand-in for the runner's run.sh in tests: records who ran it and the
# environment a job would inherit, into /out (a directory the test mounts).
set -euo pipefail
echo "uid=$(id -u) groups=$(id -Gn)" >/out/run.txt
env | sort >/out/run-env.txt
