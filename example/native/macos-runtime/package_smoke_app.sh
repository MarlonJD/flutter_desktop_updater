#!/bin/sh

set -eu

fail() {
  echo "desktop_updater macOS runtime smoke packaging: $*" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "expected one output .app path"

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=${DESKTOP_UPDATER_PACKAGE_PATH:-$(CDPATH= cd -- "$script_dir/../../.." && pwd)}
app_bundle=$1
allowed_install_root=${DESKTOP_UPDATER_RUNTIME_ALLOWED_INSTALL_ROOT:?DESKTOP_UPDATER_RUNTIME_ALLOWED_INSTALL_ROOT is required}
package_id=${DESKTOP_UPDATER_RUNTIME_PACKAGE_ID:-com.example.native-runtime-smoke}
app_name=${DESKTOP_UPDATER_RUNTIME_APP_NAME:-NativeRuntimeSmoke}
app_version=${DESKTOP_UPDATER_RUNTIME_APP_VERSION:-2.7.0}
app_build=${DESKTOP_UPDATER_RUNTIME_APP_BUILD_NUMBER:-270}
helper_id=${DESKTOP_UPDATER_RUNTIME_HELPER_SERVICE_ID:-$package_id.helper}
policy_id=${DESKTOP_UPDATER_RUNTIME_POLICY_ID:-$package_id.runtime-smoke}
code_sign_identity=${DESKTOP_UPDATER_RUNTIME_CODE_SIGN_IDENTITY:--}
team_id=${DESKTOP_UPDATER_RUNTIME_TEAM_ID:-}
notary_profile=${DESKTOP_UPDATER_RUNTIME_NOTARY_PROFILE:-}
pkg_output=${DESKTOP_UPDATER_RUNTIME_PKG_OUTPUT:-}
pkg_installer_identity=${DESKTOP_UPDATER_RUNTIME_PKG_INSTALLER_IDENTITY:-}
pkg_receipt_id=${DESKTOP_UPDATER_RUNTIME_PKG_RECEIPT_ID:-$package_id.pkg}
archs=${DESKTOP_UPDATER_RUNTIME_ARCHS:-$(/usr/bin/uname -m)}

case "$app_bundle" in
  /*.app) ;;
  *) fail "output must be an absolute .app path" ;;
esac
case "$allowed_install_root" in
  /*) ;;
  *) fail "allowed install root must be absolute" ;;
esac
case "$package_id:$helper_id:$policy_id" in
  *[!A-Za-z0-9._:+-]*) fail "package, helper, and policy identifiers must be simple dotted identifiers" ;;
esac
case "$app_version" in
  *[!0-9.+-]*) fail "version contains unsupported characters" ;;
esac
case "$app_build" in
  *[!0-9]*) fail "build number must contain only digits" ;;
esac
if [ -n "$team_id" ]; then
  case "$team_id" in
    *[!A-Z0-9]*) fail "team identifier must contain only uppercase letters and digits" ;;
  esac
fi
if [ -n "$pkg_output" ]; then
  case "$pkg_output" in
    /*.pkg) ;;
    *) fail "PKG output must be an absolute .pkg path" ;;
  esac
  [ -n "$pkg_installer_identity" ] || \
    fail "PKG output requires DESKTOP_UPDATER_RUNTIME_PKG_INSTALLER_IDENTITY"
  case "$pkg_receipt_id" in
    *[!A-Za-z0-9._-]*|'') fail "PKG receipt identifier is invalid" ;;
  esac
  [ ! -e "$pkg_output" ] || fail "PKG output already exists: $pkg_output"
fi

[ -d "$repo_root/macos/install_helper" ] || fail "repository install helper package is unavailable"
[ ! -e "$app_bundle" ] || fail "output app already exists: $app_bundle"
/bin/mkdir -p "$allowed_install_root" "$(/usr/bin/dirname "$app_bundle")"
allowed_install_root=$(CDPATH= cd -- "$allowed_install_root" && pwd -P)

work=${DESKTOP_UPDATER_RUNTIME_PACKAGE_WORK_DIR:-$(/usr/bin/dirname "$app_bundle")/.desktop-updater-runtime-package}
/bin/mkdir -p "$work"
runtime_scratch="$work/runtime-build"

DESKTOP_UPDATER_PACKAGE_PATH="$repo_root" \
  /usr/bin/swift build --disable-sandbox --package-path "$script_dir" \
    -c release --scratch-path "$runtime_scratch"
runtime_bin_path=$(DESKTOP_UPDATER_PACKAGE_PATH="$repo_root" \
  /usr/bin/swift build --disable-sandbox --package-path "$script_dir" \
    -c release --scratch-path "$runtime_scratch" --show-bin-path)
runtime_binary="$runtime_bin_path/MacOSRuntimeCompile"
[ -x "$runtime_binary" ] || fail "SwiftPM runtime executable is unavailable"

contents="$app_bundle/Contents"
/bin/mkdir -p "$contents/MacOS" "$contents/Resources"
/usr/bin/install -m 0755 "$runtime_binary" \
  "$app_bundle/Contents/MacOS/MacOSRuntimeCompile"
/usr/bin/printf '%s\n' "$app_version" > "$contents/Resources/version.txt"
/usr/bin/printf \
  'desktop_updater macOS production smoke\nappName=%s\npackageId=%s\n' \
  "$app_name" "$package_id" \
  > "$contents/Resources/desktop_updater_smoke_owner.txt"

app_info="$contents/Info.plist"
/usr/bin/plutil -create xml1 "$app_info"
/usr/bin/plutil -insert CFBundleIdentifier -string "$package_id" "$app_info"
/usr/bin/plutil -insert CFBundleExecutable -string MacOSRuntimeCompile "$app_info"
/usr/bin/plutil -insert CFBundleName -string "$app_name" "$app_info"
/usr/bin/plutil -insert CFBundleDisplayName -string "$app_name" "$app_info"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$app_info"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$app_version" "$app_info"
/usr/bin/plutil -insert CFBundleVersion -string "$app_build" "$app_info"
/usr/bin/plutil -insert LSMinimumSystemVersion -string 13.0 "$app_info"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$app_info"

app_requirement="identifier \"$package_id\""
helper_requirement="identifier \"$helper_id\""
if [ -n "$team_id" ]; then
  app_requirement="$app_requirement and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\""
  helper_requirement="$helper_requirement and anchor apple generic and certificate leaf[subject.OU] = \"$team_id\""
fi

policy="$work/DesktopUpdaterRuntimeSmokePolicy.json"
DESKTOP_UPDATER_RUNTIME_POLICY_APP_REQUIREMENT="$app_requirement" \
DESKTOP_UPDATER_RUNTIME_POLICY_HELPER_REQUIREMENT="$helper_requirement" \
DESKTOP_UPDATER_RUNTIME_POLICY_ALLOWED_ROOT="$allowed_install_root" \
DESKTOP_UPDATER_RUNTIME_POLICY_APP_ID="$package_id" \
DESKTOP_UPDATER_RUNTIME_POLICY_HELPER_ID="$helper_id" \
DESKTOP_UPDATER_RUNTIME_POLICY_ID_VALUE="$policy_id" \
  /usr/bin/python3 - "$policy" <<'PY'
import json
import os
import sys

policy = {
    "allowedApplicationSigner": {
        "kind": "appleDesignatedRequirement",
        "value": os.environ["DESKTOP_UPDATER_RUNTIME_POLICY_APP_REQUIREMENT"],
    },
    "allowedHelperSigner": {
        "kind": "appleDesignatedRequirement",
        "value": os.environ["DESKTOP_UPDATER_RUNTIME_POLICY_HELPER_REQUIREMENT"],
    },
    "allowedInstallRoots": [
        os.environ["DESKTOP_UPDATER_RUNTIME_POLICY_ALLOWED_ROOT"]
    ],
    "allowedStrategies": [
        {"provider": "platformDirectory", "strategy": "directoryReplace"},
        {"provider": "macosInstaller", "strategy": "verifiedInstallerHandoff"},
    ],
    "allowedTargetClasses": ["applicationBundle", "protectedApplication"],
    "applicationPackageId": os.environ["DESKTOP_UPDATER_RUNTIME_POLICY_APP_ID"],
    "helperServiceId": os.environ["DESKTOP_UPDATER_RUNTIME_POLICY_HELPER_ID"],
    "minimumHelperProtocolVersion": 1,
    "policyId": os.environ["DESKTOP_UPDATER_RUNTIME_POLICY_ID_VALUE"],
    "policyVersion": 3,
    "releaseRootPublicKeys": [
        {
            "algorithm": "ed25519",
            "keyId": "native-runtime-smoke-stable",
            "publicKeyBase64": "uvxxvq06xeS2PpyCFu5xo0quxlci7tvKcotOmzzM45Y=",
        }
    ],
}
with open(sys.argv[1], "w", encoding="utf-8", newline="") as output:
    output.write(json.dumps(policy, sort_keys=True, separators=(",", ":")))
PY
policy_sha256=$(/usr/bin/shasum -a 256 "$policy" | /usr/bin/awk '{print $1}')

TARGET_BUILD_DIR=$(/usr/bin/dirname "$app_bundle") \
CONTENTS_FOLDER_PATH="$(/usr/bin/basename "$app_bundle")/Contents" \
DERIVED_FILE_DIR="$work/helper-build" \
ARCHS="$archs" \
EXPANDED_CODE_SIGN_IDENTITY="$code_sign_identity" \
DESKTOP_UPDATER_HELPER_INFO_TEMPLATE="$repo_root/macos/install_helper/Configuration/Helper-Info.plist" \
DESKTOP_UPDATER_SEALED_POLICY_PATH="$policy" \
DESKTOP_UPDATER_SEALED_POLICY_SHA256="$policy_sha256" \
  "$repo_root/macos/install_helper/embed_install_helper.sh"

if [ "$code_sign_identity" = "-" ]; then
  /usr/bin/codesign --force --options runtime \
    --identifier "$package_id" \
    -r="designated => $app_requirement" \
    --sign "$code_sign_identity" "$app_bundle"
else
  /usr/bin/codesign --force --options runtime --timestamp \
    --identifier "$package_id" \
    -r="designated => $app_requirement" \
    --sign "$code_sign_identity" "$app_bundle"
fi

[ -x "$app_bundle/Contents/Helpers/DesktopUpdaterInstallHelper" ] || \
  fail "packaged helper is missing"
[ -f "$app_bundle/Contents/Library/LaunchDaemons/$helper_id.plist" ] || \
  fail "packaged LaunchDaemon metadata is missing"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
if [ -n "$notary_profile" ]; then
  [ "$code_sign_identity" != "-" ] || \
    fail "notarization requires a non-ad-hoc code-signing identity"
  notary_archive="$work/MacOSRuntimeSmoke-notary.zip"
  (
    cd "$(/usr/bin/dirname "$app_bundle")"
    /usr/bin/ditto -c -k --keepParent \
      "$(/usr/bin/basename "$app_bundle")" "$notary_archive"
  )
  /usr/bin/xcrun notarytool submit "$notary_archive" \
    --keychain-profile "$notary_profile" --wait
  /usr/bin/xcrun stapler staple "$app_bundle"
  /usr/bin/xcrun stapler validate "$app_bundle"
  /usr/sbin/spctl --assess --type execute --verbose=2 "$app_bundle"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app_bundle"
fi

if [ -n "$pkg_output" ]; then
  pkg_root="$work/pkg-root"
  component_pkg="$work/component.pkg"
  /bin/rm -rf "$pkg_root"
  /bin/rm -f "$component_pkg"
  /bin/mkdir -p "$pkg_root" "$(/usr/bin/dirname "$pkg_output")"
  /usr/bin/ditto "$app_bundle" "$pkg_root/$(/usr/bin/basename "$app_bundle")"
  /usr/bin/pkgbuild \
    --root "$pkg_root" \
    --install-location /Applications \
    --identifier "$pkg_receipt_id" \
    --version "$app_version" \
    "$component_pkg"
  /usr/bin/productbuild \
    --package "$component_pkg" \
    --sign "$pkg_installer_identity" \
    "$pkg_output"
  if [ -n "$notary_profile" ]; then
    /usr/bin/xcrun notarytool submit "$pkg_output" \
      --keychain-profile "$notary_profile" --wait
    /usr/bin/xcrun stapler staple "$pkg_output"
    /usr/bin/xcrun stapler validate "$pkg_output"
  fi
  /usr/sbin/pkgutil --check-signature "$pkg_output"
  /usr/sbin/spctl --assess --type install --verbose=2 "$pkg_output"
fi
/usr/bin/printf '%s\n' "$app_bundle"
if [ -n "$pkg_output" ]; then
  /usr/bin/printf '%s\n' "$pkg_output"
fi
