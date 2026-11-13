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
# macos-15 installs macOS 15.6.1 with Lume's sequoia preset.
# macos-26 installs macOS 26.6.2 with Lume's tahoe preset.
# Both guests then install the same Xcode. Xcode 27.1 requires macOS 26.6,
# so the pin is 26.3, the newest release that runs on macOS 15.6.1 as well.
# GH_RUNNERS_MACOS_IPSW overrides the restore image with a local file or a URL.
# GH_RUNNERS_XCODE_XIP overrides the Xcode archive with a local file. The
# SHA-256 check still applies.
# The Mac that runs this must support that release.
# Push uses GHCR_USER and GHCR_TOKEN. When GHCR_TOKEN is empty and gh is
# logged in, the script uses that token and does not print it.
set -euo pipefail

tag=${1:-macos-15}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
registry=ghcr.io
org=aphelion-works
image_name=gh-runner-images
# Checked weekly by scripts/check-macos-runner.sh. Bump this and runner_sha
# together when that check reports a newer actions/runner release.
runner_version=2.338.2
runner_sha=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388
# Xcode 26.3 (17C529). SHA-256 of Xcode_26.3_Universal.xip, the installer
# archive GitHub's macOS runner images verify.
xcode_version=26.3
xcode_file=Xcode_26.3_Universal.xip
xcode_url=https://download.developer.apple.com/Developer_Tools/Xcode_26.3/Xcode_26.3_Universal.xip
xcode_sha=cf87232e0419785170edcfa070b750f28808ec00b489ab540c08b7d197c79ae4
password=${GH_RUNNERS_MACOS_PASSWORD:-lume}

die() { printf 'build-macos-image: %s\n' "$*" >&2; exit 1; }

case $tag in
  macos-15)
    preset=sequoia
    default_ipsw=https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw
    ;;
  macos-26)
    preset=tahoe
    default_ipsw=https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw
    ;;
  *) die "tag must be macos-15 or macos-26" ;;
esac
ipsw=${GH_RUNNERS_MACOS_IPSW:-$default_ipsw}

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

if [[ $ipsw == http://* || $ipsw == https://* ]]; then
  cache="${HOME}/.cache/gh-runners"
  mkdir -p "$cache"
  dest="${cache}/${ipsw##*/}"
  printf 'downloading %s\n' "${ipsw##*/}"
  curl -fL --retry 5 -C - -o "$dest" "$ipsw"
  ipsw=$dest
fi

work=$(mktemp -d)
share="${work}/share"
mkdir -p "$share"
# The shared directory has to stay until the VM has stopped. Removing it
# while lume run still has it mounted takes the guest off the network.
cleanup() {
  if [[ -n ${lume_pid:-} ]] && kill -0 "$lume_pid" 2>/dev/null; then
    lume stop "$tag" --force >/dev/null 2>&1 || true
    wait "$lume_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

archive="${share}/actions-runner-osx-arm64-${runner_version}.tar.gz"
curl -fsSL -o "$archive" \
  "https://github.com/actions/runner/releases/download/v${runner_version}/actions-runner-osx-arm64-${runner_version}.tar.gz"
got=$(shasum -a 256 "$archive")
[[ ${got%% *} == "$runner_sha" ]] || die "runner archive does not match its published SHA-256"
printf 'installing Xcode %s\n' "$xcode_version"
xip=${GH_RUNNERS_XCODE_XIP:-}
if [[ -z $xip ]]; then
  cache="${HOME}/.cache/gh-runners"
  mkdir -p "$cache"
  xip="${cache}/${xcode_file}"
  if [[ ! -f $xip ]]; then
    printf 'downloading %s\n' "$xcode_file"
    curl -fL --retry 5 -o "$xip" "$xcode_url" \
      || die "could not download ${xcode_file}. Save the archive from a signed-in Apple developer session and set GH_RUNNERS_XCODE_XIP."
  fi
fi
[[ -f $xip ]] || die "Xcode archive ${xip} does not exist"
got=$(shasum -a 256 "$xip")
[[ ${got%% *} == "$xcode_sha" ]] || die "Xcode archive does not match its published SHA-256"
cp "$xip" "${share}/${xcode_file}"
install -m 0755 "${root}/macos/start-runner.sh" "${share}/start-runner.sh"
install -m 0644 "${root}/macos/io.gh-runners.guest.plist" "${share}/io.gh-runners.guest.plist"

printf 'creating %s from %s (%s)\n' "$tag" "$ipsw" "$preset"
# Create and set up in two steps. `lume create --unattended` deletes the VM
# when its own SSH client cannot log in. That client can time out even after
# the guest is listening, so a failed check must leave the disk in place.
# The system ssh below is what decides whether setup worked.
lume create "$tag" --ipsw "$ipsw" --cpu 4 --memory 8GB
lume setup "$tag" --unattended "$preset" || true

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
printf 'waiting for ssh on %s\n' "$ip"
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18; do
  if DISPLAY=dummy SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
    GH_RUNNERS_MACOS_PASSWORD="$password" \
    ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    -o ConnectTimeout=8 \
    "lume@${ip}" true; then
    ready=1
    break
  fi
  sleep 10
done
[[ $ready -eq 1 ]] || die "VM ${tag} did not accept ssh"
quoted=$(printf '%q' "$password")
guest_log="${work}/guest.log"
# The lume user can write its home directory. /usr/local and LaunchDaemons
# belong to root, and shutdown does too. A closed connection after the guest
# has halted is exit 255, which is success once the marker is present.
set +e
DISPLAY=dummy SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
  GH_RUNNERS_MACOS_PASSWORD="$password" \
  ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known" \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  "lume@${ip}" "GH_RUNNERS_MACOS_PASSWORD=${quoted} bash -s" <<'REMOTE' | tee "$guest_log"
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
compgen -G "${share}/Xcode_"*.xip >/dev/null \
  || { printf 'Xcode archive is not mounted\n' >&2; exit 1; }
as_root() {
  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    printf '%s\n' "$GH_RUNNERS_MACOS_PASSWORD" | sudo -S -p '' "$@"
  fi
}
install -d -o lume -g staff /Users/lume/actions-runner
tar -xzf "${share}/actions-runner-osx-arm64-"*.tar.gz -C /Users/lume/actions-runner
chown -R lume:staff /Users/lume/actions-runner
as_root install -d /usr/local/lib/gh-runners
as_root install -m 0755 "${share}/start-runner.sh" /usr/local/lib/gh-runners/start-runner.sh
as_root install -m 0644 "${share}/io.gh-runners.guest.plist" /Library/LaunchDaemons/io.gh-runners.guest.plist
# as_root feeds sudo its own stdin, so the sudoers line has to be a file.
printf 'lume ALL=(ALL) NOPASSWD: ALL\n' > /tmp/lume-sudoers
as_root install -m 0440 /tmp/lume-sudoers /etc/sudoers.d/lume
as_root visudo -cf /etc/sudoers.d/lume
rm -f /tmp/lume-sudoers
cd /Users/lume
xip --expand "${share}/Xcode_"*.xip
[[ -d /Users/lume/Xcode.app ]] || { printf 'xip did not produce Xcode.app\n' >&2; exit 1; }
as_root mv /Users/lume/Xcode.app /Applications/Xcode.app
as_root xcode-select -s /Applications/Xcode.app
as_root xcodebuild -license accept
as_root xcodebuild -runFirstLaunch
xcodebuild -version
printf 'guest setup complete\n'
as_root shutdown -h +1
REMOTE
status=${PIPESTATUS[0]}
set -e
if [[ $status -ne 0 && $status -ne 255 ]]; then
  die "guest setup failed"
fi
grep -q 'guest setup complete' "$guest_log" || die "guest setup failed"
for ((i = 0; i < 120; i++)); do
  if ! kill -0 "$lume_pid" 2>/dev/null; then
    break
  fi
  sleep 2
done
if kill -0 "$lume_pid" 2>/dev/null; then
  die "VM ${tag} did not shut down"
fi
wait "$lume_pid" 2>/dev/null || true

user=${GHCR_USER:-}
token=${GHCR_TOKEN:-}
if [[ -z $token ]] && command -v gh >/dev/null; then
  token=$(gh auth token)
  if [[ -z $user ]]; then
    user=$(gh api user --jq .login)
  fi
fi
[[ -n $user && -n $token ]] || die "set GHCR_USER and GHCR_TOKEN, or log in with gh"
# lume 0.7 reads the registry login from the environment. It has no
# --username or --password flags.
GHCR_USERNAME="$user" GHCR_TOKEN="$token" \
  lume push "$tag" "${image_name}:${tag}" \
  --registry "$registry" --organization "$org"
printf 'pushed %s/%s/%s:%s\n' "$registry" "$org" "$image_name" "$tag"
