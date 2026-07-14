#!/bin/sh

set -eu

fail() {
  echo "desktop_updater helper verification: $*" >&2
  exit 1
}

[ "$#" -eq 5 ] || fail "expected app, helper ID, requirement, info, and policy"
app_bundle=$1
helper_id=$2
helper_requirement=$3
generated_info=$4
canonical_policy=$5

app_info="$app_bundle/Contents/Info.plist"
one_shot="$app_bundle/Contents/Helpers/DesktopUpdaterInstallHelper"
launch_daemon="$app_bundle/Contents/Library/LaunchDaemons/$helper_id.plist"

for required_file in "$app_info" "$one_shot" "$launch_daemon" "$generated_info" "$canonical_policy"; do
  [ -f "$required_file" ] || fail "required retail artifact is missing: $required_file"
done

/usr/bin/codesign --verify --strict --verbose=2 "$one_shot"

actual_requirement=$(/usr/bin/codesign -d -r- "$one_shot" 2>&1 |
  /usr/bin/sed -n 's/^designated => //p')
[ -n "$actual_requirement" ] || fail "signed helper has no designated requirement"
/usr/bin/codesign --verify --strict -R="$helper_requirement" "$one_shot"

archs=$(/usr/bin/lipo -archs "$one_shot")
[ -n "$archs" ] || fail "signed helper has no Mach-O architectures"
for arch in $archs; do
  embedded_info="$generated_info.embedded.$arch"
  /usr/bin/otool -arch "$arch" -v -s __TEXT __info_plist "$one_shot" |
    /usr/bin/sed -n '/^<?xml version=/,$p' > "$embedded_info"
  /usr/bin/perl -0pi -e 's/\n\n\z/\n/' "$embedded_info"
  /usr/bin/plutil -lint "$embedded_info" >/dev/null
  /usr/bin/cmp -s "$embedded_info" "$generated_info" || \
    fail "signed helper architecture $arch does not embed the generated policy metadata"
done

host_requirement=$(/usr/bin/plutil -extract DesktopUpdaterInstallHelperRequirement raw -o - "$app_info")
[ "$host_requirement" = "$helper_requirement" ] || \
  fail "host helper requirement is not sealed"
host_helper_id=$(/usr/bin/plutil -extract DesktopUpdaterInstallHelperServiceID raw -o - "$app_info")
[ "$host_helper_id" = "$helper_id" ] || \
  fail "host one-shot helper service identifier is not sealed"
host_plist_name=$(/usr/bin/plutil -extract DesktopUpdaterInstallHelperLaunchDaemonPlistName raw -o - "$app_info")
[ "$host_plist_name" = "$helper_id.plist" ] || \
  fail "host launch daemon plist name is not sealed"

launch_label=$(/usr/bin/plutil -extract Label raw -o - "$launch_daemon")
[ "$launch_label" = "$helper_id" ] || fail "launch daemon label mismatch"
bundle_program=$(/usr/bin/plutil -extract BundleProgram raw -o - "$launch_daemon")
[ "$bundle_program" = "Contents/Helpers/DesktopUpdaterInstallHelper" ] || \
  fail "launch daemon BundleProgram mismatch"
/usr/libexec/PlistBuddy -c "Print :MachServices:$helper_id" "$launch_daemon" | \
  /usr/bin/grep -qx true || fail "launch daemon Mach service mismatch"

info_helper_id=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$embedded_info")
[ "$info_helper_id" = "$helper_id" ] || fail "helper identifier metadata mismatch"
embedded_policy="$embedded_info.policy"
/usr/bin/plutil -extract DesktopUpdaterSealedPolicy raw -o - "$embedded_info" |
  /usr/bin/base64 -D > "$embedded_policy"
/usr/bin/cmp -s "$embedded_policy" "$canonical_policy" || \
  fail "helper sealed policy bytes do not match the retail policy"
expected_policy_sha=$(/usr/bin/shasum -a 256 "$canonical_policy" | /usr/bin/awk '{print $1}')
embedded_policy_sha=$(/usr/bin/plutil -extract DesktopUpdaterSealedPolicySHA256 raw -o - "$embedded_info")
[ "$embedded_policy_sha" = "$expected_policy_sha" ] || \
  fail "helper sealed policy digest mismatch"
