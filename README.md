# gh-runner-images

[![Images](https://github.com/Aphelion-Works/gh-runner-images/actions/workflows/images.yml/badge.svg)](https://github.com/Aphelion-Works/gh-runner-images/actions/workflows/images.yml)

Container images for **single-use, self-hosted GitHub Actions runners**, built
from GitHub's official [runner release](https://github.com/actions/runner/releases)
on Ubuntu and rebuilt automatically. Made for gh-runners, which runs one container per job
under systemd.

Each container registers one runner, takes one job, and exits. It brings its
own Docker daemon, so `docker build`, service containers and `container:` jobs
work and are wiped with the container. Jobs run as the non-root `runner` user
(uid 1001) with passwordless `sudo`. A command that needs root, such as
`apt-get install`, has to use `sudo`.

## Images

`ghcr.io/aphelion-works/gh-runner-images:<tag>`, linux/amd64:

| Tag | Contents |
|---|---|
| `ubuntu-24.04` | Ubuntu 24.04, the runner, Docker Engine (+ Compose, Buildx), git, curl, jq, zip/unzip, sudo |
| `ubuntu-24.04-tools` | the above plus common CI tools (below). **Recommended for gh-runners.** |
| `ubuntu-26.04` | as `ubuntu-24.04`, on Ubuntu 26.04 |

Tools in `-tools`: build-essential (gcc, g++, make), pkg-config and common dev
headers (OpenSSL, curl, libpq, libyaml, libffi, zlib), Python 3 with pip, venv
and pipx, Node.js (Ubuntu's), shellcheck, git-lfs, GitHub CLI, yq, zstd, bzip2,
rsync, wget, ssh, ping, dig, netcat.

Each Linux tag also exists pinned:

- `ubuntu-24.04-2.338.2`: moves only within that runner version
- `ubuntu-24.04-2.338.2-20261113`: never moves

`ubuntu-24.04-tools` and `ubuntu-26.04` use the same two suffixes. There is
no `latest`: pick an Ubuntu release explicitly. The macOS tag has no suffix.

### macOS

macOS images are arm64 VMs, not containers. A Mac host pulls one with Lume
and clones it for each job. `scripts/build-macos-image.sh` builds them on an
Apple Silicon Mac and pushes them to this same registry. GitHub-hosted
runners cannot build them, and the daily workflow does not. The disk is not
stored in git.

| Tag | Guest |
|---|---|
| `macos-26` | macOS 26.6.2, Xcode 27.2 at `/Applications/Xcode.app`, the Actions runner, one job then shutdown. The published image still has the hand-installed Xcode 27.1 until it is rebuilt. |
| `macos-15` | macOS 15.6.1, Xcode 26.3 at `/Applications/Xcode.app`, the Actions runner, one job then shutdown. Published without Xcode until it is rebuilt. Xcode 27 requires macOS 26.6. |

A signing certificate is not in the image. A job imports one, as on
GitHub-hosted runners.

The guest user is `lume`, with passwordless sudo. The host passes the JIT
config in through Lume's shared folder, and the VM shuts down after the job.
Building `macos-15` needs a Mac that can boot macOS 15. `macos-26` needs a
Mac on macOS 26 or newer.

### Updates

[`images.yml`](.github/workflows/images.yml) runs daily at 01:17 UTC. It builds
each Linux image with the newest runner release, tests it, scans it, and
publishes it only if the tests pass. macOS images are published separately,
from a Mac.
[`macos-runner.yml`](.github/workflows/macos-runner.yml) runs weekly and opens
an issue when `runner_version` in `scripts/build-macos-image.sh` is behind the
latest actions/runner release. That is the signal to rebuild the macOS images.

New runner releases are picked up the same day. Ubuntu and Docker packages are
refreshed weekly. On other days only the small runner layer can change, so hosts
that pull daily download little. GitHub stops sending jobs to runners more than
30 days behind its latest release, and the daily build keeps the images well
inside that.

## Using with gh-runners

In `/etc/gh-runners/runners.conf` on the host:

```bash
IMAGES="ghcr.io/aphelion-works/gh-runner-images:ubuntu-24.04-tools"
```

Then refresh the image and restart the slots:

```bash
sudo gh-runners pull && sudo gh-runners apply
```

A restart kills jobs that are running, so check `sudo gh-runners github` for busy
runners first.

## Running it by hand

```bash
docker run --rm --privileged --mount type=volume,dst=/var/lib/docker \
  -e RUNNER_TOKEN=<registration token> -e ORG_NAME=Acme-Platform \
  -e EPHEMERAL=true -e DISABLE_AUTO_UPDATE=true -e START_DOCKER_SERVICE=true \
  ghcr.io/aphelion-works/gh-runner-images:ubuntu-24.04-tools
```

Get a registration token from
`POST /orgs/{org}/actions/runners/registration-token`; it's valid for an hour.

| Variable | Meaning |
|---|---|
| `RUNNER_TOKEN` | registration token (required to register). Jobs never see it. Refused when `RUNNER_JITCONFIG` is set. |
| `RUNNER_SCOPE` | `org` or `repo` (default: `org` when `ORG_NAME` is set) |
| `ORG_NAME` / `REPO_URL` | where to register; `REPO_URL` is the full repo URL |
| `LABELS` | extra labels, comma separated |
| `RUNNER_GROUP` | runner group (default `Default`) |
| `RUNNER_NAME` | exact name; otherwise `RUNNER_NAME_PREFIX` (default: hostname) plus 13 random characters |
| `RANDOM_RUNNER_SUFFIX` | `false` to use the prefix as the name |
| `RUNNER_WORKDIR` | default `/_work/<runner name>` |
| `EPHEMERAL` | `true`: one job, then exit |
| `DISABLE_AUTO_UPDATE` | `true`: the runner doesn't update itself (the image is updated instead) |
| `NO_DEFAULT_LABELS` | `true`: no `self-hosted`, `Linux`, `X64` labels |
| `START_DOCKER_SERVICE` | `true`: start Docker for jobs (needs `--privileged`) |
| `GITHUB_HOST` | default `github.com` |
| `RUNNER_JITCONFIG` | When set, skip registration and run `run.sh --jitconfig`. Registration settings and `RUNNER_TOKEN`, `ACCESS_TOKEN`, and `APP_*` are refused (registration settings are part of the JIT config and are not accepted in JIT mode). `START_DOCKER_SERVICE=true` still starts Docker. The JIT config is removed from the environment before the runner starts. |

`ACCESS_TOKEN`, `APP_ID`, `APP_PRIVATE_KEY` and `APP_LOGIN` are refused.
Long-lived credentials stay on the host, and only a one-hour registration
token enters the container on the registration path. In JIT mode every `APP_*`
variable is refused, and the container receives only `RUNNER_JITCONFIG`. The
image never deregisters, because single-use runners are removed by GitHub.

Any command given after the image name runs as `runner` instead of registering,
which is useful for checking an image. When `RUNNER_JITCONFIG` is set, that
command is ignored and the runner starts with the JIT config:

```bash
docker run --rm --privileged -e START_DOCKER_SERVICE=true IMAGE docker info
```

## Verifying an image

Every published Linux image carries signed build-provenance and SBOM
attestations. The macOS VMs do not. Check a Linux image with:

```bash
gh attestation verify oci://ghcr.io/aphelion-works/gh-runner-images:ubuntu-24.04-tools \
  --owner Aphelion-Works
```

## Security

- **Downloads are checked:**
  - The runner and yq are checked against the SHA-256 digests GitHub publishes for
    each release asset.
  - Docker's apt key is checked by fingerprint, and the GitHub CLI keyring by its
    published SHA-256.
  - CI tools are pinned with checksums, and every GitHub Action is pinned to a
    commit SHA.
- **Scanning:** findings appear under *Security → Code scanning*.
  - Trivy scans each Linux image.
  - CodeQL analyses the workflows.
  - Dependency review checks pull requests.
- **Where CI runs:** CI runs on GitHub's own runners, never on the runners that
  use these images. Workflows from outside contributors need approval before
  they run.
- **Reporting:** see [SECURITY.md](SECURITY.md) to report a vulnerability.

## Development

Building needs Docker. Testing also needs network access, to pull busybox for
the Docker-in-Docker check, but no GitHub access: the runner's `config.sh` and
`run.sh` are replaced by stand-ins.

```bash
scripts/build.sh ubuntu-24.04-tools        # builds gh-runner-images:ubuntu-24.04-tools
tests/test-image.sh gh-runner-images:ubuntu-24.04-tools tools
```

Lint, as CI does:

```bash
shellcheck -S style scripts/*.sh tests/*.sh tests/fake-runner/*.sh rootfs/usr/local/bin/entrypoint.sh .github/scripts/*.sh
tests/check-macos-runner.sh
tests/check-macos-xcode.sh
```

```bash
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.15.1 hadolint - < Dockerfile
```

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
```

A macOS build is `scripts/build-macos-image.sh macos-26` or `macos-15`. The
script installs the OS, the Actions runner, passwordless sudo, and Xcode.
`macos-15` gets Xcode 26.3, the newest release that runs on macOS 15.6.1.
`macos-26` gets Xcode 27.2, which requires macOS 26.6.
