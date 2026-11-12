#!/usr/bin/env bash
# Build a macOS runner VM and push it to ghcr.io/aphelion-works/gh-runner-images.
#
# GitHub-hosted runners cannot boot a macOS guest, so this runs on an Apple
# Silicon Mac with Lume installed. The result is an OCI image in the same
# registry as the Linux images. The disk is not committed to git.
#
#   scripts/build-macos-image.sh macos-15
#   scripts/build-macos-image.sh macos-26
#
# macos-15 uses Lume's sequoia unattended preset. macos-26 uses tahoe.
# GH_RUNNERS_MACOS_IPSW overrides the restore image (default: latest).
# The preset and the restore image must be the same macOS release.
# Push uses GHCR_USER and GHCR_TOKEN. When GHCR_TOKEN is empty and gh is
# logged in, the script uses that token and does not print it.
set -euo pipefail

tag=${1:-macos-15}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
registry=ghcr.io
org=aphelion-works
image_name=gh-runner-images
runner_version=2.338.2
runner_sha=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388
ipsw=${GH_RUNNERS_MACOS_IPSW:-latest}
password=${GH_RUNNERS_MACOS_PASSWORD:-lume}

die() { printf 'build-macos-image: %s\n' "$*" >&2; exit 1; }

case $tag in
  macos-15) preset=sequoia ;;
  macos-26) preset=tahoe ;;
  *) die "tag must be macos-15 or macos-26" ;;
esac

[[ $(uname -s) == Darwin ]] || die "macOS images are built on a Mac"
command -v lume >/dev/null || die "lume is not installed (https://cua.ai/docs/lume)"
command -v ssh >/dev/null || die "ssh is required"
[[ $tag =~ ^[A-Za-z0-9._-]+$ ]] || die "tag must be letters, numbers, dots, or dashes"

have_vm() {
  lume ls --format json | python3 -c '
import json, sys
name = sys.argv[1]
data = json.load(sys.stdin)
if isinstance(data, dict):
    data = data.get("VMs", data.get("vms", []))
if not isinstance(data, list):
    sys.exit(1)
for vm in data:
    if vm.get("name") == name or vm.get("Name") == name:
        sys.exit(0)
sys.exit(1)
' "$tag"
}

if have_vm; then
  die "VM ${tag} already exists. Run: lume delete ${tag} --force"
fi

work=$(mktemp -d)
share="${work}/share"
mkdir -p "$share"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

archive="${share}/actions-runner-osx-arm64-${runner_version}.tar.gz"
curl -fsSL -o "$archive" \
  "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-osx-arm64-${runner_version}.tar.gz"
got=$(shasum -a 256 "$archive")
[[ ${got%% *} == "$runner_sha" ]] || die "runner archive does not match its published SHA-256"
install -m 0755 "${root}/macos/start-runner.sh" "${share}/start-runner.sh"
install -m 0644 "${root}/macos/io.gh-runners.guest.plist" "${share}/io.gh-runners.guest.plist"

printf 'creating %s from %s (%s)\n' "$tag" "$ipsw" "$preset"
lume create "$tag" --ipsw "$ipsw" --unattended "$preset" --cpu 4 --memory 8GB

askpass="${work}/askpass"
cat >"$askpass" <<'EOF'
#!/bin/sh
printf '%s\n' "$GH_RUNNERS_MACOS_PASSWORD"
EOF
chmod 0700 "$askpass"

lume run "$tag" --display none --vnc disabled --shared-dir "$share" &
lume_pid=$!
ip=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if ip=$(lume get "$tag" --format json 2>/dev/null | python3 -c '
import json, sys
def walk(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key.lower() in {"ip", "ipaddress"} and isinstance(item, str) and item:
                print(item)
                return True
            if walk(item):
                return True
    elif isinstance(value, list):
        for item in value:
            if walk(item):
                return True
    return False
sys.exit(0 if walk(json.load(sys.stdin)) else 1)
'); then
    [[ -n $ip ]] && break
  fi
  ip=""
  sleep 10
done
[[ -n $ip ]] || die "VM ${tag} did not get an address"

known="${work}/known_hosts"
DISPLAY=dummy SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
  GH_RUNNERS_MACOS_PASSWORD="$password" \
  ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "lume@${ip}" 'bash -s' <<'REMOTE'
set -euo pipefail
share="/Volumes/My Shared Files"
if [[ -d ${share}/share ]]; then
  share="${share}/share"
fi
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [[ -d $share ]] && compgen -G "${share}/actions-runner-osx-arm64-"*.tar.gz >/dev/null && break
  sleep 2
done
compgen -G "${share}/actions-runner-osx-arm64-"*.tar.gz >/dev/null \
  || { printf 'runner archive is not mounted\n' >&2; exit 1; }
install -d -o lume -g staff /Users/lume/actions-runner
tar -xzf "${share}/actions-runner-osx-arm64-"*.tar.gz -C /Users/lume/actions-runner
chown -R lume:staff /Users/lume/actions-runner
install -d /usr/local/lib/gh-runners
install -m 0755 "${share}/start-runner.sh" /usr/local/lib/gh-runners/start-runner.sh
install -m 0644 "${share}/io.gh-runners.guest.plist" /Library/LaunchDaemons/io.gh-runners.guest.plist
shutdown -h now
REMOTE

wait "$lume_pid" || true

user=${GHCR_USER:-}
token=${GHCR_TOKEN:-}
if [[ -z $token ]] && command -v gh >/dev/null; then
  token=$(gh auth token)
  if [[ -z $user ]]; then
    user=$(gh api user --jq .login)
  fi
fi
[[ -n $user && -n $token ]] || die "set GHCR_USER and GHCR_TOKEN, or log in with gh"
lume push "$tag" "${image_name}:${tag}" \
  --registry "$registry" --organization "$org" \
  --username "$user" --password "$token"
printf 'pushed %s/%s/%s:%s\n' "$registry" "$org" "$image_name" "$tag"
