#!/bin/sh
set -eu

if [ "$#" -ne 2 ] || [ "$1" != "--mode" ]; then
  echo "usage: $0 --mode unprivileged|root-broker-audit|root-broker" >&2
  exit 64
fi

require_root_owned_sealed_file() {
  protected_file=$1
  expected_mode=$2
  test -f "$protected_file"
  test ! -L "$protected_file"
  test "$(stat -c %u "$protected_file")" -eq 0
  test "$(stat -c %g "$protected_file")" -eq 0
  test "$(stat -c %h "$protected_file")" -eq 1
  mode_bits=$(stat -c %a "$protected_file")
  test "$mode_bits" = "$expected_mode"
  case "$mode_bits" in
    *[2367][0-9]|*[0-9][2367])
      echo "$protected_file is group/world writable" >&2
      exit 77
      ;;
  esac
}

expect_result_field() {
  result_file=$1
  expected_field=$2
  if ! grep -Fx "$expected_field" "$result_file" >/dev/null; then
    echo "missing result field: $expected_field" >&2
    sed -n '1,20p' "$result_file" >&2 || true
    exit 77
  fi
}

transaction_from_result() {
  sed -n 's/^transaction=//p' "$1"
}

mode=$2
case "$mode" in
  unprivileged)
    if [ "$(id -u)" -eq 0 ]; then
      echo "unprivileged smoke must not run as root" >&2
      exit 77
    fi
    build_dir=${DESKTOP_UPDATER_LINUX_BUILD_DIR:-linux/native/build}
    helper=${DESKTOP_UPDATER_LINUX_HELPER:-$build_dir/desktop-updater-helper}
    native_test=$build_dir/desktop_updater_native_test
    test -x "$helper"
    test -x "$native_test"
    "$helper" --version
    filter='LinuxNativeInstall.PublicCommitMutatesAfterCallerExitAndQueriesDurableState:LinuxNativeInstall.PublicRecoverConvergesAfterKilledCommitHelper'
    discovered=$(
      "$native_test" --gtest_filter="$filter" --gtest_list_tests |
        awk '/^  [A-Za-z0-9_]/ { count += 1 } END { print count + 0 }'
    )
    if [ "$discovered" -ne 2 ]; then
      echo "Linux public helper smoke discovered $discovered tests; expected 2" >&2
      exit 77
    fi
    "$native_test" --gtest_filter="$filter" --gtest_color=no
    printf '%s\n' \
      'platform=linux' \
      'suite=public-native-helper-mutation-query-recovery' \
      'publicNativeApi=true' \
      'packagedHelper=true' \
      'authenticatedSocket=true' \
      'realMutation=true' \
      'durableQuery=true' \
      'crashRecovery=true' \
      "testCount=$discovered"
    ;;
  root-broker-audit)
    if [ "$(id -u)" -ne 0 ]; then
      echo "installed broker static audit must run as root" >&2
      exit 77
    fi
    helper=/usr/libexec/desktop-updater-helper
    caller=${DESKTOP_UPDATER_LINUX_E2E_CALLER:-/usr/libexec/desktop-updater-polkit-e2e-fixture}
    package_id=${DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID:?DESKTOP_UPDATER_LINUX_POLICY_PACKAGE_ID is required}
    expected_helper_sha=${DESKTOP_UPDATER_LINUX_HELPER_SHA256:?DESKTOP_UPDATER_LINUX_HELPER_SHA256 is required}
    expected_caller_sha=${DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256:?DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256 is required}
    allowed_root=${DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT:?DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT is required}
    policy=/etc/desktop-updater/policies/$package_id.json
    action=/usr/share/polkit-1/actions/com.desktopupdater.install.policy
    require_root_owned_sealed_file "$helper" 755
    require_root_owned_sealed_file "$caller" 755
    require_root_owned_sealed_file "$policy" 644
    require_root_owned_sealed_file "$action" 644
    test -x "$helper"
    test -x "$caller"
    command -v jq >/dev/null
    actual_helper_sha=$(sha256sum "$helper" | awk '{print $1}')
    actual_caller_sha=$(sha256sum "$caller" | awk '{print $1}')
    test "$actual_helper_sha" = "$expected_helper_sha"
    test "$actual_caller_sha" = "$expected_caller_sha"
    grep -aF 'desktop-updater-polkit-e2e-crash-after-backup' "$helper" >/dev/null
    jq -e \
      --arg package_id "$package_id" \
      --arg helper_sha "$expected_helper_sha" \
      --arg caller_sha "$expected_caller_sha" \
      --arg allowed_root "$allowed_root" \
      '.applicationPackageId == $package_id and
       .brokerPath == "/usr/libexec/desktop-updater-helper" and
       .helperSha256 == $helper_sha and
       (.canonicalPolicyJson | fromjson |
         .applicationPackageId == $package_id and
         .allowedHelperSigner == {"kind":"sha256","value":$helper_sha} and
         .allowedApplicationSigner == {"kind":"sha256","value":$caller_sha} and
         .allowedInstallRoots == [$allowed_root] and
         .allowedTargetClasses == ["protectedApplication"] and
         (.releaseRootPublicKeys | length) == 1 and
         .releaseRootPublicKeys[0].keyId == "polkit-e2e-test-key-1")' \
      "$policy" >/dev/null
    actual_policy_sha=$(jq -j '.canonicalPolicyJson' "$policy" | sha256sum | awk '{print $1}')
    expected_policy_sha=$(jq -r '.canonicalPolicySha256' "$policy")
    test "$actual_policy_sha" = "$expected_policy_sha"
    grep -F '<action id="com.desktopupdater.install">' "$action" >/dev/null
    grep -F '<annotate key="org.freedesktop.policykit.exec.path">/usr/libexec/desktop-updater-helper</annotate>' "$action" >/dev/null
    "$helper" --version
    printf '%s\n' \
      'platform=linux' \
      'suite=installed-polkit-root-broker-static-audit' \
      'installedBroker=true' \
      'sealedPolicy=true' \
      'polkitMetadata=true' \
      'realElevation=false'
    ;;
  root-broker)
    if [ "$(id -u)" -eq 0 ]; then
      echo "root-broker E2E must not run as root" >&2
      exit 77
    fi
    command -v pkexec >/dev/null
    command -v jq >/dev/null
    command -v sudo >/dev/null
    command -v sha256sum >/dev/null
    helper=/usr/libexec/desktop-updater-helper
    source_caller=${DESKTOP_UPDATER_LINUX_E2E_CALLER:-/usr/libexec/desktop-updater-polkit-e2e-fixture}
    expected_helper_sha=${DESKTOP_UPDATER_LINUX_HELPER_SHA256:?DESKTOP_UPDATER_LINUX_HELPER_SHA256 is required}
    expected_caller_sha=${DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256:?DESKTOP_UPDATER_LINUX_E2E_CALLER_SHA256 is required}
    target_parent=${DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT:?DESKTOP_UPDATER_LINUX_E2E_ALLOWED_ROOT is required}
    target_leaf=Example.AppDir
    target=$target_parent/$target_leaf
    target_caller=$target/linux_polkit_e2e_fixture
    crash_marker=/var/lib/desktop-updater/desktop-updater-polkit-e2e-crash-after-backup

    target_parent_leaf=${target_parent#/opt/}
    case "$target_parent" in
      /opt/desktop-updater-polkit-e2e-*) ;;
      *)
        echo "polkit E2E target root must be a dedicated /opt child" >&2
        exit 77
        ;;
    esac
    case "$target_parent_leaf" in
      */*|'')
        echo "polkit E2E target root must have exactly one derived leaf" >&2
        exit 77
        ;;
    esac
    test -n "${XDG_RUNTIME_DIR:-}"
    test "$(stat -c %u "$XDG_RUNTIME_DIR")" -eq "$(id -u)"
    test "$(stat -c %a "$XDG_RUNTIME_DIR")" = 700
    require_root_owned_sealed_file "$helper" 755
    require_root_owned_sealed_file "$source_caller" 755
    test "$(sha256sum "$helper" | awk '{print $1}')" = "$expected_helper_sha"
    test "$(sha256sum "$source_caller" | awk '{print $1}')" = "$expected_caller_sha"
    test ! -e "$target_parent"

    work=$(mktemp -d "${TMPDIR:-/tmp}/desktop-updater-polkit-e2e.XXXXXX")
    first_transaction=
    crash_transaction=
    cleanup() {
      sudo -n rm -f -- "$crash_marker" >/dev/null 2>&1 || true
      if [ -n "$first_transaction" ]; then
        sudo -n rm -f -- \
          "/var/lib/desktop-updater/transactions/$first_transaction.json" \
          "/var/lib/desktop-updater/transactions/$first_transaction.json.next" \
          >/dev/null 2>&1 || true
      fi
      if [ -n "$crash_transaction" ]; then
        sudo -n rm -f -- \
          "/var/lib/desktop-updater/transactions/$crash_transaction.json" \
          "/var/lib/desktop-updater/transactions/$crash_transaction.json.next" \
          >/dev/null 2>&1 || true
      fi
      sudo -n rm -rf -- "$target_parent" >/dev/null 2>&1 || true
      rm -rf -- "$work"
    }
    trap cleanup EXIT HUP INT TERM

    identity=$work/install-identity.json
    old_version=$work/old-version.txt
    printf '{"packageId":"com.example.desktop-updater.polkit-e2e","schemaVersion":1}' >"$identity"
    printf old >"$old_version"
    sudo -n install -d -o root -g root -m 0755 "$target_parent" "$target"
    sudo -n install -o root -g root -m 0755 "$source_caller" "$target_caller"
    sudo -n install -o root -g root -m 0644 "$identity" "$target/.desktop_updater_install_identity.json"
    sudo -n install -o root -g root -m 0644 "$old_version" "$target/version.txt"

    first_stage=$work/desktop_updater_stage_11111111-1111-4111-8111-111111111111
    first_result=$work/first-install.txt
    first_query=$work/first-query.txt
    "$target_caller" --prepare-stage "$first_stage" 2.0.0
    "$target_caller" --install "$target" "$first_stage" "$first_result"
    expect_result_field "$first_result" 'state=2'
    expect_result_field "$first_result" 'code=1'
    first_transaction=$(transaction_from_result "$first_result")
    test -n "$first_transaction"
    activated=false
    attempt=0
    while [ "$attempt" -lt 400 ]; do
      if [ -f "$target/version.txt" ] &&
         [ "$(cat "$target/version.txt")" = 2.0.0 ]; then
        activated=true
        break
      fi
      attempt=$((attempt + 1))
      sleep 0.025
    done
    test "$activated" = true
    query_completed=false
    attempt=0
    while [ "$attempt" -lt 40 ]; do
      "$target_caller" --query "$first_transaction" "$first_query"
      if grep -Fx 'state=3' "$first_query" >/dev/null &&
         grep -Fx 'code=2' "$first_query" >/dev/null; then
        query_completed=true
        break
      fi
      attempt=$((attempt + 1))
      sleep 0.025
    done
    test "$query_completed" = true
    expect_result_field "$first_query" 'state=3'
    expect_result_field "$first_query" 'code=2'
    test "$(stat -c %u "$target")" -eq 0
    test "$(stat -c %u "$target_caller")" -eq 0
    test -z "$(find "$target" ! -user root -print -quit)"
    for control_name in \
      .desktop_updater_artifact.zip \
      .desktop_updater_release_manifest.json \
      .desktop_updater_stage_provenance.json \
      .desktop_updater_payload_seal.json; do
      test ! -e "$target/$control_name"
    done

    crash_stage=$work/desktop_updater_stage_22222222-2222-4222-8222-222222222222
    crash_result=$work/crash-install.txt
    crash_query=$work/crash-query.txt
    recovery_result=$work/recovery.txt
    final_query=$work/final-query.txt
    "$target_caller" --prepare-stage "$crash_stage" 3.0.0
    printf crash-after-backup >"$work/crash-marker"
    sudo -n install -d -o root -g root -m 0700 /var/lib/desktop-updater
    sudo -n install -o root -g root -m 0600 "$work/crash-marker" "$crash_marker"
    "$target_caller" --install "$target" "$crash_stage" "$crash_result"
    expect_result_field "$crash_result" 'state=2'
    expect_result_field "$crash_result" 'code=1'
    crash_transaction=$(transaction_from_result "$crash_result")
    test -n "$crash_transaction"
    prefix=.$target_leaf.desktop-updater-$crash_transaction
    backup=$target_parent/$prefix.backup
    prepared=$target_parent/$prefix.prepared
    journal=$target_parent/$prefix.journal.json
    control=$target_parent/$prefix.control
    crashed_after_backup=false
    attempt=0
    while [ "$attempt" -lt 400 ]; do
      if [ -d "$backup" ] && [ -d "$prepared" ] &&
         [ -f "$journal" ] && [ ! -e "$target" ]; then
        crashed_after_backup=true
        break
      fi
      attempt=$((attempt + 1))
      sleep 0.025
    done
    test "$crashed_after_backup" = true
    crashed_helper_pid=$(jq -r .ownerProcessId "$journal")
    crashed_helper_start=$(jq -r .ownerProcessStartIdentity "$journal")
    helper_dead=false
    attempt=0
    while [ "$attempt" -lt 400 ]; do
      if [ ! -r "/proc/$crashed_helper_pid/stat" ]; then
        helper_dead=true
        break
      fi
      observed_state=$(awk '{print $3}' "/proc/$crashed_helper_pid/stat")
      observed_start=$(awk '{print $22}' "/proc/$crashed_helper_pid/stat")
      if [ "$observed_state" = Z ] ||
         [ "$observed_start" != "$crashed_helper_start" ]; then
        helper_dead=true
        break
      fi
      attempt=$((attempt + 1))
      sleep 0.025
    done
    test "$helper_dead" = true
    sudo -n rm -f -- "$crash_marker"

    "$source_caller" --query "$crash_transaction" "$crash_query"
    expect_result_field "$crash_query" 'state=1'
    expect_result_field "$crash_query" 'code=7'
    "$source_caller" --recover "$crash_transaction" "$recovery_result"
    expect_result_field "$recovery_result" 'state=3'
    expect_result_field "$recovery_result" 'code=2'
    test "$(cat "$target/version.txt")" = 3.0.0
    test ! -e "$backup"
    test ! -e "$prepared"
    test ! -e "$journal"
    test ! -e "$control"
    "$target_caller" --query "$crash_transaction" "$final_query"
    expect_result_field "$final_query" 'state=3'
    expect_result_field "$final_query" 'code=2'
    test "$(stat -c %u "$target")" -eq 0
    test "$(stat -c %u "$target_caller")" -eq 0
    test -z "$(find "$target" ! -user root -print -quit)"

    printf '%s\n' \
      'platform=linux' \
      'suite=installed-polkit-root-broker-e2e' \
      'publicNativeApi=true' \
      'pkexecFixedBroker=true' \
      'authenticatedSocket=true' \
      'callerRunsAsRoot=false' \
      'targetRootOwned=true' \
      'realMutation=true' \
      'durableQuery=true' \
      'crashPoint=afterBackupRename' \
      'freshBrokerRecovery=true' \
      'recoveryConverged=true'
    ;;
  *)
    echo "unknown smoke mode: $mode" >&2
    exit 64
    ;;
esac
