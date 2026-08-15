#!/usr/bin/env bash
set -euo pipefail

source_root=/home/marlonjd/desktop-updater-polkit-e2e-20260815-1
build_root="$source_root/build-polkit"
environment_file="$source_root/polkit-e2e.env"
package_id=com.example.desktop-updater.polkit-e2e
allowed_root=/opt/desktop-updater-polkit-e2e-local-20260815-1
installed_helper=/usr/libexec/desktop-updater-helper
installed_caller=/usr/libexec/desktop-updater-polkit-e2e-fixture
installed_action=/usr/share/polkit-1/actions/com.desktopupdater.install.policy
installed_policy="/etc/desktop-updater/policies/$package_id.json"
crash_marker=/var/lib/desktop-updater/desktop-updater-polkit-e2e-crash-after-backup

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "mode requires root" >&2
    exit 77
  fi
}

load_environment() {
  if [ ! -f "$environment_file" ]; then
    echo "missing environment evidence: $environment_file" >&2
    exit 77
  fi
  # The generated file contains only fixed identifiers, absolute paths, and
  # lowercase hexadecimal digests produced by this harness.
  # shellcheck disable=SC1090
  source "$environment_file"
  export DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID
  export DESKTOP_UPDATER_LINUX_HELPER_SHA256
  export DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256
  export DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT
  export DESKTOP_UPDATER_LINUX_E2E_CALLER
}

mode=${1:-}
case "$mode" in
  prepare)
    if [ "$(id -u)" -eq 0 ]; then
      echo "prepare must run as the unprivileged test user" >&2
      exit 77
    fi
    helper_sha=$(sha256sum "$build_root/desktop-updater-helper" | awk '{print $1}')
    caller_sha=$(sha256sum "$build_root/linux_polkit_e2e_fixture" | awk '{print $1}')
    canonical_policy_json=$(
      "$build_root/linux_polkit_e2e_fixture" --canonical-policy \
        "$caller_sha" "$helper_sha" "$allowed_root"
    )
    test "$(printf '%s' "$canonical_policy_json" | jq -cS .)" = \
      "$canonical_policy_json"
    canonical_policy_sha=$(
      printf '%s' "$canonical_policy_json" | sha256sum | awk '{print $1}'
    )
    escaped_policy_json=$(printf '%s' "$canonical_policy_json" | jq -Rs .)
    escaped_policy_json=${escaped_policy_json#\"}
    escaped_policy_json=${escaped_policy_json%\"}
    cmake -S "$source_root/linux/native" -B "$build_root" \
      -DDESKTOP_UPDATER_INSTALL_SYSTEM_BROKER=ON \
      "-DDESKTOP_UPDATER_HELPER_POLICY_PACKAGE_ID=$package_id" \
      "-DDESKTOP_UPDATER_HELPER_SHA256=$helper_sha" \
      "-DDESKTOP_UPDATER_HELPER_CANONICAL_POLICY_JSON=$escaped_policy_json" \
      "-DDESKTOP_UPDATER_HELPER_CANONICAL_POLICY_SHA256=$canonical_policy_sha"
    cmake --build "$build_root" \
      --target desktop-updater-helper linux_polkit_e2e_fixture
    test "$(sha256sum "$build_root/desktop-updater-helper" | awk '{print $1}')" = \
      "$helper_sha"
    test "$(sha256sum "$build_root/linux_polkit_e2e_fixture" | awk '{print $1}')" = \
      "$caller_sha"
    printf '%s\n' \
      "DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID=$package_id" \
      "DESKTOP_UPDATER_LINUX_HELPER_SHA256=$helper_sha" \
      "DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256=$caller_sha" \
      "DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT=$allowed_root" \
      "DESKTOP_UPDATER_LINUX_E2E_CALLER=$installed_caller" \
      "CANONICAL_POLICY_SHA256=$canonical_policy_sha" \
      >"$environment_file"
    cat "$environment_file"
    ;;
  install)
    require_root
    load_environment
    test ! -e "$allowed_root"
    install -d -o root -g root -m 0755 \
      /usr/libexec /usr/share/polkit-1/actions \
      /etc/desktop-updater/policies
    install -o root -g root -m 0755 \
      "$build_root/desktop-updater-helper" "$installed_helper"
    install -o root -g root -m 0755 \
      "$build_root/linux_polkit_e2e_fixture" "$installed_caller"
    install -o root -g root -m 0644 \
      "$build_root/com.desktopupdater.install.policy" "$installed_action"
    install -o root -g root -m 0644 \
      "$build_root/$package_id.json" "$installed_policy"
    systemctl start polkit.service
    systemctl is-active polkit.service
    ;;
  audit)
    require_root
    load_environment
    env \
      DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID="$DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID" \
      DESKTOP_UPDATER_LINUX_HELPER_SHA256="$DESKTOP_UPDATER_LINUX_HELPER_SHA256" \
      DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256="$DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256" \
      DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT="$DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT" \
      DESKTOP_UPDATER_LINUX_E2E_CALLER="$DESKTOP_UPDATER_LINUX_E2E_CALLER" \
      sh "$source_root/tool/linux_install_helper_smoke.sh" --mode root-broker-audit
    ;;
  run)
    if [ "$(id -u)" -eq 0 ]; then
      echo "run must execute as the unprivileged test user" >&2
      exit 77
    fi
    load_environment
    command -v pkexec >/dev/null
    command -v pkttyagent >/dev/null
    sudo -v
    pkttyagent --process "$$" &
    agent_pid=$!
    stop_agent() {
      kill "$agent_pid" >/dev/null 2>&1 || true
      wait "$agent_pid" >/dev/null 2>&1 || true
    }
    trap stop_agent EXIT HUP INT TERM
    sleep 0.2
    sh "$source_root/tool/linux_install_helper_smoke.sh" --mode root-broker
    ;;
  cleanup)
    require_root
    load_environment
    rm -f -- \
      "$crash_marker" \
      "$installed_helper" \
      "$installed_caller" \
      "$installed_action" \
      "$installed_policy"
    case "$allowed_root" in
      /opt/desktop-updater-polkit-e2e-*)
        rm -rf -- "$allowed_root"
        ;;
      *)
        echo "refusing unexpected cleanup root: $allowed_root" >&2
        exit 77
        ;;
    esac
    ;;
  *)
    echo "usage: $0 prepare|install|audit|run|cleanup" >&2
    exit 64
    ;;
esac
