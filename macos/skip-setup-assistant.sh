#!/bin/bash
# Marks every Setup Assistant screen as already seen.
#
# A guest that only finished the first-boot assistant still opens the per-user
# one (Siri, Screen Time, Apple Intelligence, Appearance) after auto-login.
# That window stays in front, so XCTest finds the app under test in the
# background and cannot click it.
#
# The key names come from the guest's own Setup Assistant binary, so a newer
# macOS that adds a screen is covered without editing this script. The two
# version keys are always written, even when the binary cannot be read.
set -euo pipefail

defaults=${GH_RUNNERS_DEFAULTS:-defaults}
strings=${GH_RUNNERS_STRINGS:-strings}
assistant=${GH_RUNNERS_SETUP_ASSISTANT:-/System/Library/CoreServices/Setup Assistant.app/Contents/MacOS/Setup Assistant}
system_domain=${GH_RUNNERS_SETUP_SYSTEM:-/Library/Preferences/com.apple.SetupAssistant}
template_root=${GH_RUNNERS_USER_TEMPLATE:-/Library/User Template}
done_file=${GH_RUNNERS_SETUP_DONE:-/var/db/.AppleSetupDone}
diagnostics_file=${GH_RUNNERS_DIAGNOSTICS_DONE:-/var/db/.AppleDiagnosticsSetupDone}
skip_buddy=${GH_RUNNERS_SKIP_BUDDY:-${HOME:-/Users/lume}/.skipbuddy}

as_root() {
  if sudo -n true >/dev/null 2>&1; then
    sudo -n "$@"
  else
    printf '%s\n' "${GH_RUNNERS_MACOS_PASSWORD:-}" | sudo -S -p '' "$@"
  fi
}

version=$(sw_vers -productVersion)
build=$(sw_vers -buildVersion)

keys=()
if [[ -x $assistant ]]; then
  while IFS= read -r key; do
    [[ -n $key ]] && keys+=("$key")
  done < <("$strings" -a "$assistant" | grep -E '^(DidSee|LastSeen)' | sort -u)
fi

have_key() {
  local want=$1 key
  for key in "${keys[@]+"${keys[@]}"}"; do
    [[ $key == "$want" ]] && return 0
  done
  return 1
}
have_key LastSeenBuddyBuildVersion || keys+=(LastSeenBuddyBuildVersion)
have_key LastSeenCloudProductVersion || keys+=(LastSeenCloudProductVersion)

write_pref() {
  local domain=$1 root=$2 key=$3
  shift 3
  if [[ $root -eq 1 ]]; then
    as_root "$defaults" write "$domain" "$key" "$@"
  else
    "$defaults" write "$domain" "$key" "$@"
  fi
}

apply_domain() {
  local domain=$1 root=$2 key
  local -a args
  for key in "${keys[@]}"; do
    if [[ $key == DidSee* ]]; then
      args=(-bool true)
    elif [[ $key == *Build* ]]; then
      args=(-string "$build")
    else
      args=(-string "$version")
    fi
    write_pref "$domain" "$root" "$key" "${args[@]}"
  done
  # mbuseragent reads these at login. A partial `lume setup --unattended`
  # leaves MiniBuddyShouldLaunchToResumeSetup set, and the per-user Setup
  # Assistant opens again even when every DidSee key is true.
  write_pref "$domain" "$root" MiniBuddyShouldLaunchToResumeSetup -bool false
  write_pref "$domain" "$root" MiniBuddyLaunchReason -int 0
  write_pref "$domain" "$root" LastPreLoginTasksPerformedBuild -string "$build"
  write_pref "$domain" "$root" LastPreLoginTasksPerformedVersion -string "$version"
  write_pref "$domain" "$root" SkipFirstLoginOptimization -bool true
  write_pref "$domain" "$root" LastPrivacyBundleVersion -string "$version"
  # A completed walkthrough leaves these. FileVault and the post-clone
  # "new Mac" screens open when they are missing.
  write_pref "$domain" "$root" selectedFDEEscrowType -string DeclinedFDE
  write_pref "$domain" "$root" MiniBuddyLaunchedPostMigration -bool true
}

# macOS 26 names the process SetupAssistantSpringboard. killall of
# "Setup Assistant" does not match that, so both have to be quit.
quit_setup_assistant() {
  killall "Setup Assistant" >/dev/null 2>&1 || true
  killall SetupAssistantSpringboard >/dev/null 2>&1 || true
}

# Close it before writing. A running assistant saves its own "not finished"
# values on the way out and would overwrite the keys below.
quit_setup_assistant
apply_domain com.apple.SetupAssistant 0
apply_domain "$system_domain" 1

shopt -s nullglob
for template in "$template_root"/*/Library/Preferences; do
  apply_domain "$template/com.apple.SetupAssistant" 1
done
for home in "$template_root"/*/; do
  as_root touch "${home}.skipbuddy"
done

as_root touch "$done_file"
as_root touch "$diagnostics_file"
# .skipbuddy is what macOS 26 checks in a user's home before opening the
# per-user assistant. An empty home is treated as unfinished.
touch "$skip_buddy"
# Quit it now, so a window that was already open is not saved into the disk.
quit_setup_assistant
# Per-host loginwindow key. A finished Setup Assistant leaves this false.
# It has to be written after the assistant has quit, because quitting writes
# the in-memory "still launching" value back over it.
"$defaults" -currentHost write com.apple.loginwindow MiniBuddyLaunch -bool false
