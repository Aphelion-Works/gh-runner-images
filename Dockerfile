# syntax=docker/dockerfile:1
# =============================================================================
# Single-use GitHub Actions runner images, built from GitHub's official runner
# release on Ubuntu. Two variants from one file:
#
#   VARIANT=base    runner + its own Docker Engine + entrypoint
#   VARIANT=tools   base + common CI tools (compilers, Python, Node, shellcheck…)
#
# Layer order keeps updates small for hosts that pull daily: OS packages
# (refreshed weekly through OS_REFRESH), then tools, then the runner itself
# (changes only with RUNNER_VERSION).
# =============================================================================
ARG UBUNTU_VERSION=24.04
ARG VARIANT=base

# --- OS: runner dependencies, Docker Engine, sudo, the runner user ------------
FROM ubuntu:${UBUNTU_VERSION} AS os
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
# Any new value rebuilds the OS layers (CI passes the ISO week).
ARG OS_REFRESH=manual
COPY --chmod=755 scripts/install-base.sh /tmp/
RUN echo "OS refresh: ${OS_REFRESH}" && /tmp/install-base.sh

# --- runner: download and verify the official release -------------------------
FROM os AS runner
ARG TARGETARCH
ARG RUNNER_VERSION
ARG RUNNER_SHA256_AMD64
ARG RUNNER_SHA256_ARM64
COPY --chmod=755 scripts/install-runner.sh /tmp/
RUN /tmp/install-runner.sh /actions-runner

# --- variants ------------------------------------------------------------------
FROM os AS variant-base

FROM os AS variant-tools
ARG TARGETARCH
ARG YQ_VERSION
ARG YQ_SHA256_AMD64
ARG YQ_SHA256_ARM64
COPY --chmod=755 scripts/install-tools.sh /tmp/
RUN /tmp/install-tools.sh

# --- final image -----------------------------------------------------------------
# hadolint ignore=DL3006
FROM variant-${VARIANT} AS image
ARG IMAGE_OS=ubuntu24
ARG RUNNER_VERSION
LABEL org.opencontainers.image.source="https://github.com/Aphelion-Works/gh-runner-images" \
      org.opencontainers.image.description="Single-use GitHub Actions runner (official runner release, own Docker daemon, non-root jobs)" \
      io.github.actions.runner.version="${RUNNER_VERSION}"
ENV RUNNER_MANUALLY_TRAP_SIG=1 \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache \
    RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    ImageOS=${IMAGE_OS}
COPY --from=runner --chown=1001:1001 /actions-runner /home/runner
COPY --chmod=755 rootfs/usr/local/bin/entrypoint.sh /usr/local/bin/entrypoint.sh
WORKDIR /home/runner
# The entrypoint starts as root to run the job's Docker daemon, then runs the
# runner as the unprivileged `runner` user.
# hadolint ignore=DL3002
USER 0
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
