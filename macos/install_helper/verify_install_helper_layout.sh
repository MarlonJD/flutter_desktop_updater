#!/bin/sh

set -eu

fail() {
  echo "desktop_updater helper verification: $*" >&2
  exit 1
}

[ "$#" -eq 6 ] || fail "expected app, helper ID, requirements, info, and policy"
app_bundle=$1
helper_id=$2
application_requirement=$3
helper_requirement=$4
generated_info=$5
canonical_policy=$6

app_info="$app_bundle/Contents/Info.plist"
one_shot="$app_bundle/Contents/Helpers/DesktopUpdaterInstallHelper"
privileged="$app_bundle/Contents/Library/LaunchServices/$helper_id"

for required_file in "$app_info" "$one_shot" "$privileged" "$generated_info" "$canonical_policy"; do
  [ -f "$required_file" ] || fail "required retail artifact is missing: $required_file"
done

/usr/bin/cmp -s "$one_shot" "$privileged" || fail "nested helper payloads differ"
/usr/bin/codesign --verify --strict --verbose=2 "$one_shot"
/usr/bin/codesign --verify --strict --verbose=2 "$privileged"

actual_requirement=$(/usr/bin/codesign -d -r- "$one_shot" 2>&1 |
  /usr/bin/sed -n 's/^designated => //p')
[ -n "$actual_requirement" ] || fail "signed helper has no designated requirement"
/usr/bin/codesign --verify --strict -R="$helper_requirement" "$one_shot"
/usr/bin/codesign --verify --strict -R="$helper_requirement" "$privileged"

embedded_info="$generated_info.embedded"
/usr/bin/otool -v -s __TEXT __info_plist "$one_shot" |
  /usr/bin/sed -n '/^<?xml version=/,$p' > "$embedded_info"
/usr/bin/perl -0pi -e 's/\n\n\z/\n/' "$embedded_info"
/usr/bin/plutil -lint "$embedded_info" >/dev/null
/usr/bin/cmp -s "$embedded_info" "$generated_info" || \
  fail "signed helper does not embed the generated policy metadata"

host_requirement=$(/usr/libexec/PlistBuddy \
  -c "Print :SMPrivilegedExecutables:$helper_id" "$app_info")
[ "$host_requirement" = "$helper_requirement" ] || \
  fail "host SMPrivilegedExecutables requirement is not reciprocal"
host_helper_id=$(/usr/bin/plutil -extract DesktopUpdaterInstallHelperServiceID raw -o - "$app_info")
[ "$host_helper_id" = "$helper_id" ] || \
  fail "host one-shot helper service identifier is not sealed"
authorized_client=$(/usr/libexec/PlistBuddy \
  -c "Print :SMAuthorizedClients:0" "$embedded_info")
[ "$authorized_client" = "$application_requirement" ] || \
  fail "helper SMAuthorizedClients requirement is not reciprocal"

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
