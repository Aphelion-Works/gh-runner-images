#!/usr/bin/env bash
# =============================================================================
# entrypoint.sh: start one GitHub Actions runner in this container.
#
# Starts as root only to run the job's Docker daemon, then runs the runner as
# the unprivileged `runner` user. Settings are removed from the environment
# before the runner starts, so a job never sees the registration token.
#
# No arguments: register with RUNNER_TOKEN, then run the runner.
# RUNNER_JITCONFIG: skip registration and run `run.sh --jitconfig`. Extra
#   arguments are ignored. Registration settings, ACCESS_TOKEN, and APP_* are
#   refused. The JIT config is removed before run.sh starts.
# Arguments: run them as `runner` instead of registering.
#
# ACCESS_TOKEN, APP_ID, APP_PRIVATE_KEY, and APP_LOGIN are refused. The
# variable list is in the README.
# =============================================================================
set -euo pipefail

RUNNER_HOME=/home/runner
RUNNER_USER=runner
SETTINGS=(RUNNER_TOKEN RUNNER_SCOPE ORG_NAME REPO_URL LABELS RUNNER_GROUP RUNNER_NAME
  RUNNER_NAME_PREFIX RANDOM_RUNNER_SUFFIX RUNNER_WORKDIR EPHEMERAL DISABLE_AUTO_UPDATE
  NO_DEFAULT_LABELS START_DOCKER_SERVICE GITHUB_HOST)
# Refused when RUNNER_JITCONFIG is set: the JIT config already carries them.
# START_DOCKER_SERVICE is not here: it still starts Docker.
JIT_REGISTRATION=(RUNNER_TOKEN RUNNER_SCOPE ORG_NAME REPO_URL LABELS RUNNER_GROUP
  RUNNER_NAME RUNNER_NAME_PREFIX RANDOM_RUNNER_SUFFIX RUNNER_WORKDIR EPHEMERAL
  DISABLE_AUTO_UPDATE NO_DEFAULT_LABELS GITHUB_HOST)

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] error: %s\n' "$*" >&2; exit 1; }
is_true() { case "${1,,}" in true | 1 | yes | on) return 0 ;; *) return 1 ;; esac; }

as_runner() {  # <command...>: run as the runner user with its own HOME
  exec setpriv --reuid="$RUNNER_USER" --regid="$RUNNER_USER" --init-groups \
    env HOME="$RUNNER_HOME" USER="$RUNNER_USER" LOGNAME="$RUNNER_USER" "$@"
}

start_docker() {
  log "starting the job's Docker daemon"
  # cgroup v2: move this container's processes into a child group so the root
  # group can delegate controllers to job containers (as docker:dind does).
  # Without it, `docker run --memory/--cpus` inside the job fails.
  if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    mkdir -p /sys/fs/cgroup/init 2>/dev/null || true
    xargs -rn1 </sys/fs/cgroup/cgroup.procs >/sys/fs/cgroup/init/cgroup.procs 2>/dev/null || true
    sed -e 's/ / +/g' -e 's/^/+/' </sys/fs/cgroup/cgroup.controllers \
      >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
  fi
  dockerd --group docker >/var/log/dockerd.log 2>&1 &
  local pid=$! i
  for ((i = 0; i < 60; i++)); do
    docker info >/dev/null 2>&1 && return 0
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  tail -n 20 /var/log/dockerd.log >&2 || true
  die "the Docker daemon did not start (is the container running with --privileged?)"
}

random_suffix() {
  (set +o pipefail; tr -dc 'A-Za-z0-9' </dev/urandom | head -c 13)
}

# Variable names currently set that start with the given prefix.
vars_with_prefix() {  # <prefix>
  compgen -v "$1" || true
}

refuse_jit_conflicts() {
  local v name
  for v in "${JIT_REGISTRATION[@]}"; do
    [[ -z "${!v:-}" ]] || die "${v} is part of the JIT config and is not accepted in JIT mode"
  done
  [[ -z "${ACCESS_TOKEN:-}" ]] || die "ACCESS_TOKEN is not accepted in JIT mode"
  while IFS= read -r name; do
    [[ -n "$name" && -n "${!name:-}" ]] || continue
    die "${name} is not accepted in JIT mode"
  done < <(vars_with_prefix APP_)
}

unset_app_vars() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    unset "$name"
  done < <(vars_with_prefix APP_)
}

run_jit() {
  local jit="${RUNNER_JITCONFIG}"
  refuse_jit_conflicts
  if is_true "${START_DOCKER_SERVICE:-false}"; then start_docker; fi
  cd "$RUNNER_HOME"
  log "starting the runner with a JIT config"
  unset "${SETTINGS[@]}" RUNNER_JITCONFIG ACCESS_TOKEN
  unset_app_vars
  as_runner "${RUNNER_HOME}/run.sh" --jitconfig "$jit"
}

register_args() {  # fills the global ARGS for config.sh
  [[ -n "${RUNNER_TOKEN:-}" ]] || die "RUNNER_TOKEN is required: a registration token for the org or repo"
  local host="${GITHUB_HOST:-github.com}" scope="${RUNNER_SCOPE:-}" url name workdir
  host="${host#https://}"; host="${host#http://}"; host="${host%/}"
  scope="${scope,,}"
  if [[ -z "$scope" ]]; then
    if [[ -n "${ORG_NAME:-}" ]]; then scope=org; else scope=repo; fi
  fi
  case "$scope" in
    org)  [[ -n "${ORG_NAME:-}" ]] || die "ORG_NAME is required when RUNNER_SCOPE=org"
          url="https://${host}/${ORG_NAME}" ;;
    repo) [[ -n "${REPO_URL:-}" ]] || die "REPO_URL is required when RUNNER_SCOPE=repo"
          url="$REPO_URL" ;;
    *)    die "RUNNER_SCOPE must be org or repo, not '${RUNNER_SCOPE}'" ;;
  esac

  if [[ -n "${RUNNER_NAME:-}" ]]; then
    name="$RUNNER_NAME"
  else
    name="${RUNNER_NAME_PREFIX:-$(hostname)}"
    if is_true "${RANDOM_RUNNER_SUFFIX:-true}"; then name="${name}-$(random_suffix)"; fi
  fi
  workdir="${RUNNER_WORKDIR:-/_work/${name}}"
  install -d -o "$RUNNER_USER" -g "$RUNNER_USER" "$workdir"

  ARGS=(--unattended --replace --url "$url" --token "$RUNNER_TOKEN" --name "$name"
    --work "$workdir" --runnergroup "${RUNNER_GROUP:-Default}")
  if [[ -n "${LABELS:-}" ]]; then ARGS+=(--labels "$LABELS"); fi
  if is_true "${EPHEMERAL:-false}"; then ARGS+=(--ephemeral); fi
  if is_true "${DISABLE_AUTO_UPDATE:-false}"; then ARGS+=(--disableupdate); fi
  if is_true "${NO_DEFAULT_LABELS:-false}"; then ARGS+=(--no-default-labels); fi
  log "registering runner ${name} with ${url}"
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "start the container as root (the default); jobs run as '${RUNNER_USER}'"
  # JIT mode wins over extra arguments: those are the debug path below.
  if [[ -n "${RUNNER_JITCONFIG:-}" ]]; then run_jit; fi
  local v
  for v in ACCESS_TOKEN APP_ID APP_PRIVATE_KEY APP_LOGIN; do
    [[ -z "${!v:-}" ]] || die "$v is not accepted: pass a short-lived RUNNER_TOKEN instead"
  done

  if is_true "${START_DOCKER_SERVICE:-false}"; then start_docker; fi
  cd "$RUNNER_HOME"

  if [[ $# -gt 0 ]]; then
    unset "${SETTINGS[@]}"
    as_runner "$@"
  fi

  ARGS=()
  register_args
  unset "${SETTINGS[@]}"
  # config.sh must finish before the runner starts, so run it in a child.
  (as_runner "${RUNNER_HOME}/config.sh" "${ARGS[@]}") || die "runner registration failed"
  ARGS=()
  as_runner "${RUNNER_HOME}/run.sh"
}

main "$@"
