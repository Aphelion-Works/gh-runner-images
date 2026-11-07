# gh-runner-images

[![Images](https://github.com/Aphelion-Works/gh-runner-images/actions/workflows/images.yml/badge.svg)](https://github.com/Aphelion-Works/gh-runner-images/actions/workflows/images.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Aphelion-Works/gh-runner-images/badge)](https://scorecard.dev/viewer/?uri=github.com/Aphelion-Works/gh-runner-images)

Container images for **single-use, self-hosted GitHub Actions runners**, built
from GitHub's official [runner release](https://github.com/actions/runner/releases)
on Ubuntu and rebuilt automatically. Made for gh-runners, which runs one container per job
under systemd. They work with any setup that does the same.

Each container registers one runner, takes one job, and exits. It brings its
own Docker daemon, so `docker build`, service containers and `container:` jobs
work and are wiped with the container. Jobs run as the non-root `runner` user
(uid 1001) with passwordless `sudo`, as on GitHub's own runners.

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

Each tag also exists pinned:

- `ubuntu-24.04-2.338.2`: moves only within that runner version
- `ubuntu-24.04-2.338.2-20261106`: never moves

There is no `latest`: pick an Ubuntu release explicitly.

### Updates

[`images.yml`](.github/workflows/images.yml) runs daily at 01:17 UTC. It:

1. builds every image with the newest runner release,
2. tests it ([`tests/test-image.sh`](tests/test-image.sh)),
3. scans it, and
4. publishes it only if the tests pass.

New runner releases are picked up the same day. Ubuntu and Docker packages are
refreshed weekly. On other days only the small runner layer can change, so hosts
that pull daily download little. GitHub stops sending jobs to runners more than
30 days behind its latest release, and the daily build keeps the images well
inside that.

GitHub turns off scheduled workflows in public repositories after 60 days
without a commit, and emails a warning first. Merging the weekly Dependabot pull
requests is enough to keep the schedule running.

## Using with gh-runners

In `/etc/gh-runners/runners.conf` on the host:

```bash
RUNNER_IMAGE="ghcr.io/aphelion-works/gh-runner-images:ubuntu-24.04-tools"
```

Then refresh the image and restart the slots:

```bash
sudo gh-runners pull && sudo gh-runners apply
```

A restart kills jobs that are running, so check `sudo gh-runners github` for busy
runners first. The image accepts the settings gh-runners already passes, so
nothing else changes.

### Differences from `myoung34/github-runner`

| | myoung34/github-runner | these images |
|---|---|---|
| Runner | official release | official release, SHA-256 checked |
| Jobs run as | root | `runner` (uid 1001) with passwordless sudo |
| Credentials accepted | registration token, PAT, GitHub App key | registration token, or `RUNNER_JITCONFIG` |
| Extra tools | many (AWS CLI, PowerShell, Podman…) | `-tools` variant (list above) |
| Provenance | none | signed build provenance and SBOM attestations |

Workflows that run root-only commands without `sudo`, such as `apt-get install`,
need `sudo` added. AWS CLI, PowerShell and Podman aren't included: install them
in the job if needed.

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

`UNSET_CONFIG_VARS` and `DISABLE_AUTOMATIC_DEREGISTRATION` are accepted and
ignored, for compatibility, including in JIT mode. These settings are always
removed before the runner starts, and the image never deregisters, because
single-use runners are removed by GitHub. `ACCESS_TOKEN`, `APP_ID`,
`APP_PRIVATE_KEY` and `APP_LOGIN` are refused on purpose: long-lived credentials
stay on the host, and only a one-hour registration token enters the container
on the registration path. In JIT mode every `APP_*` variable is refused, and
the container receives only `RUNNER_JITCONFIG`.

Any command given after the image name runs as `runner` instead of registering,
which is useful for checking an image. When `RUNNER_JITCONFIG` is set, that
command is ignored and the runner starts with the JIT config:

```bash
docker run --rm --privileged -e START_DOCKER_SERVICE=true IMAGE docker info
```

## Verifying an image

Every published image carries signed build-provenance and SBOM attestations:

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
  - Trivy scans each image.
  - CodeQL analyses the workflows.
  - OpenSSF Scorecard checks the repository's practices.
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
```

```bash
docker run --rm -i -v "$PWD/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.15.1 hadolint - < Dockerfile
```

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:1.7.12
```

```
Dockerfile                      one file, two variants (VARIANT=base|tools)
rootfs/usr/local/bin/entrypoint.sh   registers and starts the runner
scripts/install-base.sh         OS packages, Docker Engine, runner user
scripts/install-runner.sh       downloads and checks the runner release
scripts/install-tools.sh        the -tools variant
scripts/resolve-versions.sh     newest runner/yq versions and their SHA-256s
scripts/build.sh                local build of one image
tests/test-image.sh             image tests (CI runs them before publishing)
```
