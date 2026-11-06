#!/usr/bin/env bash
# =============================================================================
# test-image.sh <image ref> [base|tools]: check a built image. Needs Docker and
# network access (the Docker-in-Docker check pulls busybox). No GitHub access:
# config.sh and run.sh are replaced by stand-ins that record how they're called.
#
#   EXPECTED_RUNNER_VERSION=2.338.2 tests/test-image.sh gh-runner-images:ubuntu-24.04
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${1:?usage: tests/test-image.sh <image> [base|tools]}"
VARIANT="${2:-base}"
FAILS=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; FAILS=$((FAILS + 1)); }
check() {  # <description> <command...>
  local d="$1" out; shift
  if out="$("$@" 2>&1)"; then pass "$d"; else fail "$d" "$out"; fi
}
has_line() { grep -qxF -- "$2" "$1"; }

run() { docker run --rm "$@"; }

# Runs the entrypoint with the fake config.sh/run.sh and a fresh /out.
register() {  # <env args...>
  rm -rf "$TMP/out"; mkdir -p "$TMP/out"; chmod 777 "$TMP/out"
  run -v "$TMP/out:/out" \
    -v "$PWD/fake-runner/config.sh:/home/runner/config.sh:ro" \
    -v "$PWD/fake-runner/run.sh:/home/runner/run.sh:ro" \
    "$@" "$IMAGE"
}

echo "== $IMAGE ($VARIANT)"

echo "-- user and runner"
check "commands run as runner (uid 1001)" test "$(run "$IMAGE" id -u)" = 1001
check "runner has passwordless sudo" test "$(run "$IMAGE" sudo -n id -u)" = 0
check "tini is PID 1" test "$(run "$IMAGE" cat /proc/1/comm)" = tini
version="$(run "$IMAGE" ./config.sh --version 2>/dev/null | grep -xE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1 || true)"
if [[ -n "${EXPECTED_RUNNER_VERSION:-}" ]]; then
  check "runner version is ${EXPECTED_RUNNER_VERSION}" test "$version" = "$EXPECTED_RUNNER_VERSION"
else
  check "runner reports a version (${version:-none})" test -n "$version"
fi
check "tool cache is writable by runner" run "$IMAGE" touch /opt/hostedtoolcache/x
check "work directory is writable by runner" run "$IMAGE" touch /_work/x

echo "-- registration (org)"
register -e RUNNER_TOKEN=test-registration-token -e RUNNER_SCOPE=org -e ORG_NAME=Acme-Platform \
  -e LABELS=ovh,uk -e RUNNER_GROUP=ci -e RUNNER_NAME_PREFIX=host-acme-platform-1 \
  -e RANDOM_RUNNER_SUFFIX=true -e EPHEMERAL=true -e DISABLE_AUTO_UPDATE=true \
  -e UNSET_CONFIG_VARS=true -e DISABLE_AUTOMATIC_DEREGISTRATION=true >"$TMP/log" 2>&1 \
  || fail "entrypoint exits 0" "$(cat "$TMP/log")"
c="$TMP/out/config.txt"
if [[ -f "$c" ]]; then
  check "config.sh runs as runner" has_line "$c" "uid=1001"
  check "--url is the org" has_line "$c" "arg=https://github.com/Acme-Platform"
  check "--token is passed" has_line "$c" "arg=test-registration-token"
  check "--labels" has_line "$c" "arg=ovh,uk"
  check "--runnergroup" has_line "$c" "arg=ci"
  check "--ephemeral" has_line "$c" "arg=--ephemeral"
  check "--disableupdate" has_line "$c" "arg=--disableupdate"
  check "--unattended" has_line "$c" "arg=--unattended"
  check "name is prefix + 13 random characters" grep -qE '^arg=host-acme-platform-1-[A-Za-z0-9]{13}$' "$c"
  check "work dir is /_work/<name>" grep -qE '^arg=/_work/host-acme-platform-1-[A-Za-z0-9]{13}$' "$c"
  check "config.sh doesn't see the token in its environment" bash -c "! grep -q test-registration-token '$TMP/out/config-env.txt'"
else
  fail "config.sh was called" "$(cat "$TMP/log")"
fi
r="$TMP/out/run.txt"
if [[ -f "$r" ]]; then
  check "run.sh runs as runner, in the docker group" grep -qE '^uid=1001 groups=.*\bdocker\b' "$r"
  check "jobs can't see the token" bash -c "! grep -q test-registration-token '$TMP/out/run-env.txt'"
  check "jobs don't inherit runner settings" bash -c "! grep -qE '^(RUNNER_TOKEN|ORG_NAME|LABELS|RUNNER_SCOPE|EPHEMERAL)=' '$TMP/out/run-env.txt'"
  check "HOME is the runner's" has_line "$TMP/out/run-env.txt" "HOME=/home/runner"
else
  fail "run.sh was called after config.sh" "$(cat "$TMP/log")"
fi

echo "-- registration (repo) and defaults"
register -e RUNNER_TOKEN=t -e RUNNER_SCOPE=repo -e REPO_URL=https://github.com/octo-user/demo \
  -e RANDOM_RUNNER_SUFFIX=false -e RUNNER_NAME_PREFIX=solo >/dev/null 2>&1 || true
c="$TMP/out/config.txt"
check "--url is the repo URL" has_line "$c" "arg=https://github.com/octo-user/demo"
check "RANDOM_RUNNER_SUFFIX=false keeps the prefix as the name" has_line "$c" "arg=solo"
check "runner group defaults to Default" has_line "$c" "arg=Default"
check "no --ephemeral unless asked" bash -c "! grep -qxF 'arg=--ephemeral' '$c'"

echo "-- refusals"
expect_error() {  # <description> <expected message> <env args...>
  local d="$1" msg="$2" out; shift 2
  if out="$(register "$@" 2>&1)"; then fail "$d (exited 0)" "$out"
  elif grep -qF -- "$msg" <<<"$out"; then pass "$d"
  else fail "$d" "$out"; fi
}
expect_error "no token" "RUNNER_TOKEN is required"
expect_error "org scope without ORG_NAME" "ORG_NAME is required" -e RUNNER_TOKEN=t -e RUNNER_SCOPE=org
expect_error "repo scope without REPO_URL" "REPO_URL is required" -e RUNNER_TOKEN=t -e RUNNER_SCOPE=repo
expect_error "unknown scope" "RUNNER_SCOPE must be org or repo" -e RUNNER_TOKEN=t -e RUNNER_SCOPE=enterprise -e ORG_NAME=x
expect_error "GitHub App key refused" "APP_PRIVATE_KEY is not accepted" -e RUNNER_TOKEN=t -e ORG_NAME=x -e APP_PRIVATE_KEY=k
expect_error "access token refused" "ACCESS_TOKEN is not accepted" -e RUNNER_TOKEN=t -e ORG_NAME=x -e ACCESS_TOKEN=k
expect_error "Docker without --privileged fails clearly" "did not start" -e START_DOCKER_SERVICE=true -e RUNNER_TOKEN=t -e ORG_NAME=x

echo "-- Docker in the job"
dind() { run --privileged --mount type=volume,dst=/var/lib/docker -e START_DOCKER_SERVICE=true --memory 2g "$IMAGE" "$@"; }
check "runner can use the job's Docker without sudo" dind docker info --format '{{.ServerVersion}}'
check "job containers start, with memory limits (cgroup delegation)" \
  dind bash -c 'docker run --rm --memory 64m --cpus 0.5 busybox true'
check "docker compose and buildx are installed" dind bash -c 'docker compose version && docker buildx version'

if [[ "$VARIANT" == tools ]]; then
  echo "-- tools"
  for cmd in gcc g++ make pkg-config python3 pip3 pipx node shellcheck git-lfs gh yq zstd rsync ssh wget curl jq zip unzip dig nc ping; do
    check "$cmd is installed" run "$IMAGE" bash -c "command -v $cmd"
  done
  check "python3 -m venv works" run "$IMAGE" bash -c 'python3 -m venv /tmp/v && /tmp/v/bin/pip --version'
  check "yq works" run "$IMAGE" bash -c 'echo "a: 1" | yq .a | grep -qx 1'
fi

echo
if [[ "$FAILS" -gt 0 ]]; then echo "$FAILS check(s) failed"; exit 1; fi
echo "all checks passed"
