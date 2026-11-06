# Working on gh-runner-images

- **Test before calling a change done.** Build and test each affected image, and
  fix what it reports:
  - `scripts/build.sh <image>`
  - `tests/test-image.sh <image ref> <base|tools>`

  Tests need Docker and network access, but no GitHub access.
- **New behaviour needs a test** in `tests/test-image.sh`. Entrypoint behaviour is
  tested through the stand-ins in `tests/fake-runner/`, which record how
  `config.sh` and `run.sh` were called.
- **Never commit secrets, keys, real host names or IP addresses.** Examples and
  tests use made-up names (Acme-Platform, Acme-Labs, octo-user).
- **Only a registration token may enter the container.** Keep refusing
  `ACCESS_TOKEN` and `APP_*`, and keep removing every setting from the environment
  before the runner starts, so jobs never see the token.
- **Every download is verified.**
  - Release assets: by their SHA-256.
  - apt repositories: by a key fingerprint or a keyring checksum.
  - GitHub Actions: pinned to a commit SHA, with the version in a comment.
  - CI tool versions and checksums live in `.github/scripts/install-ci-tools.sh`.
- **Linters:** shell scripts must pass `shellcheck -S style`, the Dockerfile
  `hadolint`, and workflows `actionlint`. The README's "Development" section shows
  how to run them.
- **CI runs on GitHub's own runners** (`ubuntu-24.04`), never on the
  self-hosted runners that use these images, so a broken image can't block its
  own fix.
- **Image tags are public names** that hosts depend on. Don't rename or remove one
  without a migration note in the README.
