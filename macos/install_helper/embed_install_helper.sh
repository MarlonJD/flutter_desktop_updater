#!/bin/sh

set -eu

fail() {
  echo "desktop_updater helper packaging: $*" >&2
  exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
target_build_dir=${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}
contents_folder_path=${CONTENTS_FOLDER_PATH:?CONTENTS_FOLDER_PATH is required}
derived_root=${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR:-}}
[ -n "$derived_root" ] || fail "DERIVED_FILE_DIR or TARGET_TEMP_DIR is required"

case "$contents_folder_path" in
  */Contents)
    app_bundle="$target_build_dir/${contents_folder_path%/Contents}"
    ;;
  *)
    app_bundle="$target_build_dir/$contents_folder_path"
    ;;
esac
app_info="$app_bundle/Contents/Info.plist"
info_template=${DESKTOP_UPDATER_HELPER_INFO_TEMPLATE:?DESKTOP_UPDATER_HELPER_INFO_TEMPLATE is required}
sealed_policy=${DESKTOP_UPDATER_SEALED_POLICY_PATH:?DESKTOP_UPDATER_SEALED_POLICY_PATH is required}
expected_policy_sha256=${DESKTOP_UPDATER_SEALED_POLICY_SHA256:?DESKTOP_UPDATER_SEALED_POLICY_SHA256 is required}
code_sign_identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}
[ -n "$code_sign_identity" ] || fail "CODE_SIGN_IDENTITY is required"

for required_file in "$app_info" "$info_template" "$sealed_policy"; do
  [ -f "$required_file" ] || fail "required metadata is missing: $required_file"
done

work="$derived_root/desktop-updater-install-helper"
helper_info="$work/Helper-Info.plist"
helper_launchd="$work/Helper-Launchd.plist"
canonical_policy="$work/SealedPolicy.json"
policy_plist="$work/SealedPolicy.plist"
unsigned_helper="$work/DesktopUpdaterInstallHelper.unsigned"
signed_helper="$work/DesktopUpdaterInstallHelper.signed"
mkdir -p "$work"
cp "$info_template" "$helper_info"
cp "$script_dir/Configuration/Helper-Launchd.plist" "$helper_launchd"
/usr/bin/perl -0pe 's/\r?\n\z//' "$sealed_policy" > "$canonical_policy"
/usr/bin/plutil -lint "$helper_info" >/dev/null
/usr/bin/plutil -convert xml1 -o "$policy_plist" "$canonical_policy"

application_id=$(/usr/bin/plutil -extract applicationPackageId raw -o - "$policy_plist")
policy_id=$(/usr/bin/plutil -extract policyId raw -o - "$policy_plist")
helper_id=$(/usr/bin/plutil -extract helperServiceId raw -o - "$policy_plist")
application_signer_kind=$(/usr/bin/plutil -extract allowedApplicationSigner.kind raw -o - "$policy_plist")
helper_signer_kind=$(/usr/bin/plutil -extract allowedHelperSigner.kind raw -o - "$policy_plist")
helper_requirement=$(/usr/bin/plutil -extract allowedHelperSigner.value raw -o - "$policy_plist")
host_application_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app_info")

[ "$application_signer_kind" = "appleDesignatedRequirement" ] || \
  fail "sealed application signer must be an Apple designated requirement"
[ "$helper_signer_kind" = "appleDesignatedRequirement" ] || \
  fail "sealed helper signer must be an Apple designated requirement"
[ "$host_application_id" = "$application_id" ] || \
  fail "sealed applicationPackageId does not match the host bundle"

policy_sha256=$(/usr/bin/shasum -a 256 "$canonical_policy" | /usr/bin/awk '{print $1}')
[ "$policy_sha256" = "$expected_policy_sha256" ] || \
  fail "sealed policy digest does not match the canonical packaging input"
policy_base64=$(/usr/bin/base64 < "$canonical_policy")

/usr/bin/plutil -replace CFBundleIdentifier -string "$helper_id" "$helper_info"
/usr/bin/plutil -replace DesktopUpdaterSealedPolicy -data "$policy_base64" "$helper_info"
/usr/bin/plutil -replace DesktopUpdaterSealedPolicySHA256 -string "$policy_sha256" "$helper_info"

/usr/bin/plutil -replace Label -string "$helper_id" "$helper_launchd"
/usr/libexec/PlistBuddy -c "Delete :MachServices" "$helper_launchd" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :MachServices dict" "$helper_launchd"
/usr/libexec/PlistBuddy -c "Add :MachServices:$helper_id bool true" "$helper_launchd"
/usr/bin/plutil -replace BundleProgram -string "Contents/Helpers/DesktopUpdaterInstallHelper" "$helper_launchd"

/usr/bin/plutil -replace DesktopUpdaterInstallPolicyID -string "$policy_id" "$app_info" 2>/dev/null || \
  /usr/bin/plutil -insert DesktopUpdaterInstallPolicyID -string "$policy_id" "$app_info"
/usr/bin/plutil -replace DesktopUpdaterInstallHelperServiceID -string "$helper_id" "$app_info" 2>/dev/null || \
  /usr/bin/plutil -insert DesktopUpdaterInstallHelperServiceID -string "$helper_id" "$app_info"
/usr/bin/plutil -replace DesktopUpdaterInstallHelperRequirement -string "$helper_requirement" "$app_info" 2>/dev/null || \
  /usr/bin/plutil -insert DesktopUpdaterInstallHelperRequirement -string "$helper_requirement" "$app_info"
launch_daemon_plist_name="$helper_id.plist"
/usr/bin/plutil -replace DesktopUpdaterInstallHelperLaunchDaemonPlistName -string "$launch_daemon_plist_name" "$app_info" 2>/dev/null || \
  /usr/bin/plutil -insert DesktopUpdaterInstallHelperLaunchDaemonPlistName -string "$launch_daemon_plist_name" "$app_info"

helper_info_sha256=$(/usr/bin/shasum -a 256 "$helper_info" | /usr/bin/awk '{print $1}')
helper_launchd_sha256=$(/usr/bin/shasum -a 256 "$helper_launchd" | /usr/bin/awk '{print $1}')

archs=${ARCHS:-$(/usr/bin/uname -m)}
arch_count=0
arch_outputs=""
for arch in $archs; do
  scratch="$work/build-$arch-$helper_info_sha256-$helper_launchd_sha256"
  DESKTOP_UPDATER_HELPER_INFO_PLIST="$helper_info" \
    /usr/bin/swift build --disable-sandbox --package-path "$script_dir" -c release \
      --arch "$arch" --scratch-path "$scratch"
  bin_path=$(DESKTOP_UPDATER_HELPER_INFO_PLIST="$helper_info" \
    /usr/bin/swift build --disable-sandbox --package-path "$script_dir" -c release \
      --arch "$arch" --scratch-path "$scratch" --show-bin-path)
  arch_helper="$work/DesktopUpdaterInstallHelper.$arch"
  cp "$bin_path/DesktopUpdaterInstallHelper" "$arch_helper"
  arch_outputs="$arch_outputs $arch_helper"
  arch_count=$((arch_count + 1))
done

if [ "$arch_count" -eq 1 ]; then
  cp ${arch_outputs# } "$unsigned_helper"
else
  # shellcheck disable=SC2086
  /usr/bin/lipo -create $arch_outputs -output "$unsigned_helper"
fi

cp "$unsigned_helper" "$signed_helper"
if [ "$code_sign_identity" = "-" ]; then
  /usr/bin/codesign --force --options runtime \
    --identifier "$helper_id" \
    -r="designated => $helper_requirement" \
    --sign "$code_sign_identity" "$signed_helper"
else
  /usr/bin/codesign --force --options runtime --timestamp \
    --identifier "$helper_id" \
    -r="designated => $helper_requirement" \
    --sign "$code_sign_identity" "$signed_helper"
fi

one_shot="$app_bundle/Contents/Helpers/DesktopUpdaterInstallHelper"
launch_daemon="$app_bundle/Contents/Library/LaunchDaemons/$launch_daemon_plist_name"
mkdir -p "$(dirname "$one_shot")" "$(dirname "$launch_daemon")"
/usr/bin/install -m 0755 "$signed_helper" "$one_shot"
/usr/bin/install -m 0644 "$helper_launchd" "$launch_daemon"

"$script_dir/verify_install_helper_layout.sh" \
  "$app_bundle" "$helper_id" "$helper_requirement" \
  "$helper_info" "$canonical_policy"

touch "$work/embed-complete.stamp"
