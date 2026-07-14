#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || [ "$1" != "--mode" ]; then
  echo "usage: $0 --mode unprivileged|root-broker" >&2
  exit 64
fi

mode=$2
case "$mode" in
  unprivileged)
    if [ "$(id -u)" -eq 0 ]; then
      echo "unprivileged smoke must not run as root" >&2
      exit 77
    fi
    helper=${DESKTOP_UPDATER_LINUX_HELPER:-linux/native/build/desktop-updater-helper}
    test -x "$helper"
    "$helper" --version
    ;;
  root-broker)
    test "$(id -u)" -eq 0
    helper=/usr/libexec/desktop-updater-helper
    package_id=${DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID:?DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID is required}
    expected_helper_sha=${DESKTOP_UPDATER_LINUX_HELPER_SHA256:?DESKTOP_UPDATER_LINUX_HELPER_SHA256 is required}
    policy=/etc/desktop-updater/policies/$package_id.json
    action=/usr/share/polkit-1/actions/com.desktopupdater.install.policy
    test -x "$helper"
    test "$(stat -c %u "$helper")" -eq 0
    mode_bits=$(stat -c %a "$helper")
    case "$mode_bits" in
      *[2367][0-9]|*[0-9][2367])
        echo "installed helper is group/world writable" >&2
        exit 77
        ;;
    esac
    test -f "$policy"
    test "$(stat -c %u "$policy")" -eq 0
    test -f "$action"
    test "$(stat -c %u "$action")" -eq 0
    for protected_file in "$policy" "$action"; do
      mode_bits=$(stat -c %a "$protected_file")
      case "$mode_bits" in
        *[2367][0-9]|*[0-9][2367])
          echo "installed broker metadata is group/world writable" >&2
          exit 77
          ;;
      esac
    done
    command -v jq >/dev/null
    actual_helper_sha=$(sha256sum "$helper" | awk '{print $1}')
    test "$actual_helper_sha" = "$expected_helper_sha"
    jq -e \
      --arg package_id "$package_id" \
      --arg helper_sha "$expected_helper_sha" \
      '.applicationPackageId == $package_id and
       .brokerPath == "/usr/libexec/desktop-updater-helper" and
       .helperSha256 == $helper_sha and
       (.canonicalPolicyJson | fromjson | .applicationPackageId) == $package_id' \
      "$policy" >/dev/null
    actual_policy_sha=$(jq -j '.canonicalPolicyJson' "$policy" | sha256sum | awk '{print $1}')
    expected_policy_sha=$(jq -r '.canonicalPolicySha256' "$policy")
    test "$actual_policy_sha" = "$expected_policy_sha"
    command -v pkcheck >/dev/null
    "$helper" --version
    ;;
  *)
    echo "unknown smoke mode: $mode" >&2
    exit 64
    ;;
esac
