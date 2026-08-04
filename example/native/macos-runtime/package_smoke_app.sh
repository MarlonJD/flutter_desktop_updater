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
pkg_baseline_smoke=${DESKTOP_UPDATER_RUNTIME_PKG_BASELINE_SMOKE:-0}
pkg_recovery_smoke=${DESKTOP_UPDATER_RUNTIME_PKG_RECOVERY_SMOKE:-0}
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
case "$pkg_recovery_smoke" in
  0|1) ;;
  *) fail "PKG recovery smoke flag must be 0 or 1" ;;
esac
case "$pkg_baseline_smoke" in
  0|1) ;;
  *) fail "PKG baseline smoke flag must be 0 or 1" ;;
esac
if [ "$pkg_baseline_smoke" = 1 ] && [ "$pkg_recovery_smoke" = 1 ]; then
  fail "baseline and recovery smoke flags are exclusive"
fi
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
if [ "$pkg_recovery_smoke" = 1 ]; then
  [ -n "$pkg_output" ] || fail "PKG recovery smoke requires PKG output"
  [ "$package_id" = net.monolib.updater ] || \
    fail "PKG recovery smoke requires the fixed smoke package identifier"
  [ "$pkg_receipt_id" = net.monolib.updater.pkg ] || \
    fail "PKG recovery smoke requires the fixed smoke receipt identifier"
  [ "$app_name" = 'Desktop Updater SMAppService PKG E2E' ] || \
    fail "PKG recovery smoke requires the fixed smoke application name"
  [ "$(/usr/bin/basename "$app_bundle")" = \
      'Desktop Updater SMAppService PKG E2E.app' ] || \
    fail "PKG recovery smoke requires the fixed smoke application bundle"
  [ "$app_version:$app_build" = 2.7.1:271 ] || \
    fail "PKG recovery smoke requires the fixed v2 version and build"
  [ "$allowed_install_root" = /Applications ] || \
    fail "PKG recovery smoke requires the fixed application install root"
fi
if [ "$pkg_baseline_smoke" = 1 ]; then
  [ -n "$pkg_output" ] || fail "PKG baseline smoke requires PKG output"
  [ "$package_id" = net.monolib.updater ] || \
    fail "PKG baseline smoke requires the fixed smoke package identifier"
  [ "$pkg_receipt_id" = net.monolib.updater.pkg ] || \
    fail "PKG baseline smoke requires the fixed smoke receipt identifier"
  [ "$app_name" = 'Desktop Updater SMAppService PKG E2E' ] || \
    fail "PKG baseline smoke requires the fixed smoke application name"
  [ "$(/usr/bin/basename "$app_bundle")" = \
      'Desktop Updater SMAppService PKG E2E.app' ] || \
    fail "PKG baseline smoke requires the fixed smoke application bundle"
  [ "$app_version:$app_build" = 2.7.0:270 ] || \
    fail "PKG baseline smoke requires the fixed v1 version and build"
  [ "$allowed_install_root" = /Applications ] || \
    fail "PKG baseline smoke requires the fixed application install root"
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
  if [ "$pkg_baseline_smoke" = 1 ]; then
    component_plist="$work/baseline-components.plist"
    /bin/rm -f "$component_plist"
    /usr/bin/pkgbuild --analyze --root "$pkg_root" "$component_plist"
    /usr/bin/python3 - \
      "$component_plist" "$(/usr/bin/basename "$app_bundle")" <<'PY'
import plistlib
import sys

path = sys.argv[1]
expected_bundle = sys.argv[2]
with open(path, "rb") as source:
    components = plistlib.load(source)
if not isinstance(components, list) or len(components) != 1:
    raise SystemExit("baseline component discovery must find one bundle")
component = components[0]
if not isinstance(component, dict):
    raise SystemExit("baseline component entry must be a dictionary")
if component.get("RootRelativeBundlePath") != expected_bundle:
    raise SystemExit("baseline component path does not match the fixed app")
component["BundleIsVersionChecked"] = False
component["BundleIsRelocatable"] = False
component["BundleHasStrictIdentifier"] = True
component["BundleOverwriteAction"] = "upgrade"
with open(path, "wb") as output:
    plistlib.dump(components, output, fmt=plistlib.FMT_XML, sort_keys=True)
PY
    /usr/bin/pkgbuild \
      --root "$pkg_root" \
      --component-plist "$component_plist" \
      --install-location /Applications \
      --identifier "$pkg_receipt_id" \
      --version "$app_version" \
      "$component_pkg"
  elif [ "$pkg_recovery_smoke" = 1 ]; then
    recovery_scripts="$script_dir/pkg-scripts/recovery"
    [ -d "$recovery_scripts" ] && [ ! -L "$recovery_scripts" ] || \
      fail "fixed PKG recovery scripts directory is unavailable"
    [ -f "$recovery_scripts/preinstall" ] && \
      [ ! -L "$recovery_scripts/preinstall" ] && \
      [ -x "$recovery_scripts/preinstall" ] || \
      fail "fixed PKG recovery preinstall is unavailable"
    recovery_entry_count=$(/usr/bin/find "$recovery_scripts" \
      -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$recovery_entry_count" = 1 ] || \
      fail "fixed PKG recovery scripts directory contains unexpected entries"
    /usr/bin/pkgbuild \
      --root "$pkg_root" \
      --scripts "$recovery_scripts" \
      --install-location /Applications \
      --identifier "$pkg_receipt_id" \
      --version "$app_version" \
      "$component_pkg"
  else
    /usr/bin/pkgbuild \
      --root "$pkg_root" \
      --install-location /Applications \
      --identifier "$pkg_receipt_id" \
      --version "$app_version" \
      "$component_pkg"
  fi
  if [ "$pkg_baseline_smoke" = 1 ]; then
    baseline_distribution="$work/baseline-distribution.xml"
    /bin/rm -f "$baseline_distribution"
    /usr/bin/productbuild --synthesize \
      --package "$component_pkg" "$baseline_distribution"
    /usr/bin/python3 - \
      "$baseline_distribution" "$pkg_receipt_id" "$package_id" \
      "$app_version" "$app_build" \
      "$(/usr/bin/basename "$app_bundle")" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, receipt_id, bundle_id, version, build, bundle_path = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
matches = []
for parent in root.iter():
    for child in list(parent):
        if child.tag == "bundle-version":
            matches.append((parent, child))
if len(matches) > 1:
    raise SystemExit("baseline distribution bundle-version mismatch")
if matches:
    parent, version_node = matches[0]
    bundles = list(version_node)
    if parent.tag != "pkg-ref" or parent.get("id") != receipt_id:
        raise SystemExit("baseline distribution bundle-version mismatch")
    if len(bundles) != 1 or bundles[0].tag != "bundle":
        raise SystemExit("baseline distribution bundle-version mismatch")
    expected = {
        "id": bundle_id,
        "path": bundle_path,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": build,
    }
    if bundles[0].attrib != expected:
        raise SystemExit("baseline distribution bundle-version mismatch")
    parent.remove(version_node)
options = [element for element in root.iter() if element.tag == "options"]
if len(options) != 1 or options[0].get("require-scripts") != "false":
    raise SystemExit("baseline distribution scripts authority mismatch")
if any(element.tag == "bundle-version" for element in root.iter()):
    raise SystemExit("baseline distribution bundle-version mismatch")
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
    baseline_product="$work/baseline-product.pkg"
    baseline_product_expanded="$work/baseline-product-expanded"
    baseline_product_flattened="$work/baseline-product-flattened.pkg"
    /bin/rm -f "$baseline_product" "$baseline_product_flattened"
    /bin/rm -rf "$baseline_product_expanded"
    /usr/bin/productbuild \
      --distribution "$baseline_distribution" \
      --package-path "$work" \
      "$baseline_product"
    /usr/sbin/pkgutil --expand \
      "$baseline_product" "$baseline_product_expanded"
    [ -f "$baseline_product_expanded/Distribution" ] && \
      [ ! -L "$baseline_product_expanded/Distribution" ] && \
      [ -d "$baseline_product_expanded/component.pkg" ] && \
      [ ! -L "$baseline_product_expanded/component.pkg" ] || \
      fail "baseline product shape is invalid"
    baseline_product_entry_count=$(/usr/bin/find \
      "$baseline_product_expanded" -mindepth 1 -maxdepth 1 -print | \
      /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$baseline_product_entry_count" = 2 ] || \
      fail "baseline product shape contains unexpected entries"
    for component_entry in Bom Payload PackageInfo; do
      [ -f "$baseline_product_expanded/component.pkg/$component_entry" ] && \
        [ ! -L "$baseline_product_expanded/component.pkg/$component_entry" ] || \
        fail "baseline component shape is invalid"
    done
    baseline_component_entry_count=$(/usr/bin/find \
      "$baseline_product_expanded/component.pkg" \
      -mindepth 1 -maxdepth 1 -print | \
      /usr/bin/wc -l | /usr/bin/tr -d ' ')
    [ "$baseline_component_entry_count" = 3 ] || \
      fail "baseline component shape contains unexpected entries"
    /usr/bin/python3 - \
      "$baseline_product_expanded/Distribution" \
      "$pkg_receipt_id" "$package_id" "$app_version" "$app_build" \
      "$(/usr/bin/basename "$app_bundle")" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, receipt_id, bundle_id, version, build, bundle_path = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
matches = []
for parent in root.iter():
    for child in list(parent):
        if child.tag == "bundle-version":
            matches.append((parent, child))
if len(matches) != 1:
    raise SystemExit("baseline distribution bundle-version mismatch")
parent, version_node = matches[0]
bundles = list(version_node)
expected = {
    "id": bundle_id,
    "path": bundle_path,
    "CFBundleShortVersionString": version,
    "CFBundleVersion": build,
}
if (parent.tag != "pkg-ref" or parent.get("id") != receipt_id or
        len(bundles) != 1 or bundles[0].tag != "bundle" or
        bundles[0].attrib != expected):
    raise SystemExit("baseline distribution bundle-version mismatch")
options = [element for element in root.iter() if element.tag == "options"]
if len(options) != 1 or options[0].get("require-scripts") != "false":
    raise SystemExit("baseline distribution scripts authority mismatch")
parent.remove(version_node)
if any(element.tag == "bundle-version" for element in root.iter()):
    raise SystemExit("baseline distribution bundle-version mismatch")
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
    /usr/sbin/pkgutil --flatten \
      "$baseline_product_expanded" "$baseline_product_flattened"
    /usr/bin/productsign --timestamp --sign "$pkg_installer_identity" \
      "$baseline_product_flattened" "$pkg_output"
    baseline_signed_expanded="$work/baseline-signed-expanded"
    /bin/rm -rf "$baseline_signed_expanded"
    /usr/sbin/pkgutil --expand "$pkg_output" "$baseline_signed_expanded"
    [ -d "$baseline_signed_expanded/component.pkg" ] && \
      [ ! -L "$baseline_signed_expanded/component.pkg" ] || \
      fail "signed baseline component shape is invalid"
  else
    /usr/bin/productbuild \
      --package "$component_pkg" \
      --sign "$pkg_installer_identity" \
      "$pkg_output"
  fi
  expanded_pkg="$work/expanded-product"
  /bin/rm -rf "$expanded_pkg"
  /usr/sbin/pkgutil --expand-full "$pkg_output" "$expanded_pkg"
  payload_app="$expanded_pkg/component.pkg/Payload/$(/usr/bin/basename "$app_bundle")"
  [ -d "$payload_app" ] && [ ! -L "$payload_app" ] || \
    fail "final PKG payload app is missing or not a directory"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$payload_app"
  /usr/bin/codesign --verify --strict --verbose=2 \
    "$payload_app/Contents/Helpers/DesktopUpdaterInstallHelper"
  if [ "$pkg_baseline_smoke" = 1 ]; then
    /usr/bin/python3 - \
      "$expanded_pkg/Distribution" \
      "$expanded_pkg/component.pkg/PackageInfo" \
      "$pkg_receipt_id" "$package_id" <<'PY'
import sys
import xml.etree.ElementTree as ET

distribution_path, package_info_path, receipt_id, bundle_id = sys.argv[1:]
distribution = ET.parse(distribution_path).getroot()
if any(element.tag == "bundle-version" for element in distribution.iter()):
    raise SystemExit("baseline final distribution retained bundle-version")
options = [element for element in distribution.iter()
           if element.tag == "options"]
if len(options) != 1 or options[0].get("require-scripts") != "false":
    raise SystemExit("baseline final distribution scripts authority mismatch")
package_info = ET.parse(package_info_path).getroot()
version_nodes = [element for element in package_info.iter()
                 if element.tag == "bundle-version"]
if len(version_nodes) != 1 or list(version_nodes[0]):
    raise SystemExit("baseline component retained bundle-version authority")
upgrade_ids = [element.get("id") for element in package_info.findall(
    "./upgrade-bundle/bundle"
)]
if package_info.get("identifier") != receipt_id or upgrade_ids != [bundle_id]:
    raise SystemExit("baseline component upgrade authority mismatch")
PY
  fi
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
