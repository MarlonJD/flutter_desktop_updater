# Linux Release Production Gates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Linux from debug update confidence to release production confidence by adding Release CI smoke coverage and a detached release signature verification gate for direct zip distribution.

**Architecture:** Linux has no single OS-level Developer ID or Gatekeeper equivalent. The production gate should therefore live in the shared Dart release contract: require a signed `release.json` and verify it before downloading or staging the artifact. Keep the native Linux helper focused on safe copy, rollback, removed-file containment, no current-working-directory assumptions, and relaunch.

**Tech Stack:** Flutter Linux, CMake, Bash, GitHub Actions, `desktop_updater:verify --require-signature`, Ed25519 detached release signatures, optional Minisign or a Dart Ed25519 verifier, static HTTPS hosting.

---

## File Structure

- Modify: `.github/workflows/desktop-updater-ci.yml`
  - Add Linux Release build, Release native tests, Release integration tests, and Release update smoke.
  - Add optional signed release verification gate.
- Modify: `example/tool/updater_smoke.dart`
  - Reuse `--config Debug|Release` from the Windows plan for Linux Release paths.
- Modify: `bin/verify.dart`
  - Wire a real Ed25519 verifier for `--require-signature`.
- Modify: `lib/src/core/artifact_verifier.dart`
  - Keep policy-based verification, add production verifier helpers if needed.
- Modify: `lib/src/core/release_descriptor.dart`
  - Keep canonical signature bytes stable and documented.
- Modify: `lib/src/package/zip_release_packager.dart` or create `bin/sign_release.dart`
  - Add a controlled way to sign `release.json` after packaging.
- Create: `test/linux_release_smoke_config_test.dart`
  - Lock Linux Release CI and smoke behavior.
- Create: `test/release_signature_verifier_test.dart`
  - Lock valid, invalid, missing, and wrong-key signature behavior.
- No branch operation is allowed. Commit only after explicit user approval.

---

### Task 1: Add Linux Release CI Gates

**Files:**
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/linux_release_smoke_config_test.dart`

- [ ] **Step 1: Add failing workflow test**

Create `test/linux_release_smoke_config_test.dart`:

```dart
import "dart:io";

import "package:test/test.dart";

void main() {
  test("Linux CI runs Release build, native tests, integration, and smoke", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("Build example release"));
    expect(workflow, contains("flutter build linux --release"));
    expect(workflow, contains("cmake --build build/linux/x64/release"));
    expect(workflow, contains("ctest --test-dir build/linux/x64/release"));
    expect(
      workflow,
      contains("xvfb-run -a dart run tool/updater_smoke.dart --config Release"),
    );
  });

  test("updater smoke supports Linux Release output", () {
    final source = File("example/tool/updater_smoke.dart").readAsStringSync();

    expect(source, contains("--config"));
    expect(
      source,
      contains(
        '"build", "linux", "x64", config.toLowerCase(), "bundle", "desktop_updater_example"',
      ),
    );
  });
}
```

- [ ] **Step 2: Run the failing test**

Run:

```bash
flutter test --no-pub test/linux_release_smoke_config_test.dart
```

Expected: fail until the smoke tool and workflow support Release.

- [ ] **Step 3: Add Linux Release workflow steps**

In `.github/workflows/desktop-updater-ci.yml`, after the existing Linux debug smoke, add:

```yaml
      - name: Build example release
        working-directory: example
        run: flutter build linux --release
      - name: Build native tests release
        working-directory: example
        run: cmake --build build/linux/x64/release --target desktop_updater_test
      - name: Run native tests release
        working-directory: example
        run: ctest --test-dir build/linux/x64/release --output-on-failure
      - name: Run integration tests release
        working-directory: example
        run: xvfb-run -a flutter test integration_test -d linux
      - name: Rebuild example release for smoke
        working-directory: example
        run: flutter build linux --release
      - name: Run update smoke release
        working-directory: example
        run: xvfb-run -a dart run tool/updater_smoke.dart --config Release
```

- [ ] **Step 4: Verify test passes**

Run:

```bash
flutter test --no-pub test/linux_release_smoke_config_test.dart
```

Expected: pass.

---

### Task 2: Implement Ed25519 Release Signature Verification

**Files:**
- Modify: `bin/verify.dart`
- Modify: `lib/src/core/artifact_verifier.dart`
- Create: `lib/src/core/release_signature_verifier.dart`
- Test: `test/release_signature_verifier_test.dart`

- [ ] **Step 1: Add failing verifier tests**

Create `test/release_signature_verifier_test.dart`:

```dart
import "dart:convert";

import "package:desktop_updater/src/core/release_descriptor.dart";
import "package:desktop_updater/src/core/release_signature_verifier.dart";
import "package:test/test.dart";

void main() {
  final descriptorJson = <String, dynamic>{
    "schemaVersion": 3,
    "packageId": "net.monolib.updater",
    "appName": "desktop_updater_example",
    "version": "0.1.6",
    "buildNumber": 7,
    "platform": "linux",
    "channel": "stable",
    "artifact": {
      "kind": "zip",
      "url": "https://updates.example.com/linux.zip",
      "sha256": "a" * 64,
      "length": 123,
    },
    "install": {"strategy": "wholeDirectoryReplace"},
    "minimumUpdaterVersion": "2.0.0-dev.5",
    "generatedAt": "2026-06-11T00:00:00.000Z",
    "signature": {
      "algorithm": "ed25519",
      "publicKeyId": "test-key",
      "value": "",
    },
  };

  test("verifies a valid release descriptor signature", () async {
    final keyPair = await generateTestEd25519KeyPair();
    final unsigned = ReleaseDescriptor.fromJson(descriptorJson);
    final signature = await signReleaseDescriptorForTest(unsigned, keyPair);
    final signed = ReleaseDescriptor.fromJson({
      ...descriptorJson,
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": "test-key",
        "value": base64Encode(signature),
      },
    });

    final verifier = Ed25519ReleaseSignatureVerifier({
      "test-key": await publicKeyForTest(keyPair),
    });

    expect(
      await verifier.verify(signed, signed.canonicalSignatureBytes()),
      isTrue,
    );
  });

  test("rejects a modified descriptor", () async {
    final keyPair = await generateTestEd25519KeyPair();
    final unsigned = ReleaseDescriptor.fromJson(descriptorJson);
    final signature = await signReleaseDescriptorForTest(unsigned, keyPair);
    final tampered = ReleaseDescriptor.fromJson({
      ...descriptorJson,
      "buildNumber": 8,
      "signature": {
        "algorithm": "ed25519",
        "publicKeyId": "test-key",
        "value": base64Encode(signature),
      },
    });

    final verifier = Ed25519ReleaseSignatureVerifier({
      "test-key": await publicKeyForTest(keyPair),
    });

    expect(
      await verifier.verify(tampered, tampered.canonicalSignatureBytes()),
      isFalse,
    );
  });
}
```

- [ ] **Step 2: Add an Ed25519 library dependency**

Use an existing Dart package with Ed25519 support. Prefer a maintained package already compatible with Flutter stable. Add only the minimal dependency needed for signing verification.

Expected `pubspec.yaml` change:

```yaml
dependencies:
  cryptography: ^2.7.0
```

Then run:

```bash
flutter pub get
```

- [ ] **Step 3: Implement `release_signature_verifier.dart`**

Create `lib/src/core/release_signature_verifier.dart`:

```dart
import "dart:convert";

import "package:cryptography/cryptography.dart";
import "package:desktop_updater/src/core/release_descriptor.dart";

class Ed25519ReleaseSignatureVerifier {
  const Ed25519ReleaseSignatureVerifier(this.publicKeys);

  final Map<String, SimplePublicKey> publicKeys;

  Future<bool> verify(
    ReleaseDescriptor descriptor,
    List<int> canonicalBytes,
  ) async {
    final signature = descriptor.signature;
    if (signature == null || signature.algorithm != "ed25519") {
      return false;
    }

    final publicKey = publicKeys[signature.publicKeyId];
    if (publicKey == null) {
      return false;
    }

    final value = base64Decode(signature.value);
    return Ed25519().verify(
      canonicalBytes,
      signature: Signature(value, publicKey: publicKey),
    );
  }
}
```

Add test-only helpers either inside the test file or a fixture helper.

- [ ] **Step 4: Wire CLI verification**

Update `bin/verify.dart` to read pinned public keys from an environment variable:

```dart
final publicKeysJson =
    Platform.environment["DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS"];
```

Expected value shape:

```json
{"stable-linux":"base64-raw-ed25519-public-key"}
```

When `--require-signature` is used, instantiate:

```dart
ArtifactVerifier(
  policy: ArtifactVerificationPolicy(
    requireSignature: true,
    signatureVerifier: Ed25519ReleaseSignatureVerifier(publicKeys).verify,
  ),
);
```

- [ ] **Step 5: Verify signature tests**

Run:

```bash
flutter test --no-pub test/release_signature_verifier_test.dart
```

Expected: valid signature passes; tampered descriptor fails.

---

### Task 3: Add Release Signing Tooling

**Files:**
- Create: `bin/sign_release.dart`
- Modify: `pubspec.yaml`
- Test: `test/release_signature_verifier_test.dart`

- [ ] **Step 1: Add CLI entrypoint**

Add to `pubspec.yaml`:

```yaml
executables:
  sign_release: sign_release
```

- [ ] **Step 2: Implement `bin/sign_release.dart`**

The command must:

```text
Input: --release path/to/release.json
Input: --public-key-id stable-linux
Input: --private-key-base64 from env DESKTOP_UPDATER_RELEASE_PRIVATE_KEY
Output: release.json with signature.value filled
```

Use the same `canonicalSignatureBytes()` function used by verification.

- [ ] **Step 3: Verify local signing round trip**

Run:

```bash
dart run desktop_updater:package \
  --input example/build/linux/x64/release/bundle \
  --output /tmp/desktop_updater_linux_release \
  --package-id net.monolib.updater \
  --app-name desktop_updater_example \
  --version 0.1.6 \
  --build-number 7 \
  --platform linux \
  --channel stable \
  --artifact-url https://updates.example.com/desktop_updater_linux.zip
DESKTOP_UPDATER_RELEASE_PRIVATE_KEY="<base64-private-key>" \
  dart run desktop_updater:sign_release \
  --release /tmp/desktop_updater_linux_release/release.json \
  --public-key-id stable-linux
DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS='{"stable-linux":"<base64-public-key>"}' \
  dart run desktop_updater:verify \
  --release /tmp/desktop_updater_linux_release/release.json \
  --require-signature
```

Expected: `release.json verified`.

---

### Task 4: Add Optional Linux Signed Release CI Gate

**Files:**
- Modify: `.github/workflows/desktop-updater-ci.yml`
- Test: `test/linux_release_smoke_config_test.dart`

- [ ] **Step 1: Add workflow test**

Add to `test/linux_release_smoke_config_test.dart`:

```dart
  test("Linux CI documents optional signed release verification", () {
    final workflow =
        File(".github/workflows/desktop-updater-ci.yml").readAsStringSync();

    expect(workflow, contains("LINUX_RELEASE_SIGNATURE_ENABLED"));
    expect(workflow, contains("DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS"));
    expect(workflow, contains("--require-signature"));
  });
```

- [ ] **Step 2: Add optional workflow step**

Add after Linux Release package generation, or create a package generation step first:

```yaml
      - name: Verify signed Linux release descriptor
        if: ${{ env.LINUX_RELEASE_SIGNATURE_ENABLED == 'true' }}
        working-directory: example
        env:
          LINUX_RELEASE_SIGNATURE_ENABLED: ${{ secrets.LINUX_RELEASE_SIGNATURE_ENABLED }}
          DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS: ${{ secrets.DESKTOP_UPDATER_RELEASE_PUBLIC_KEYS }}
        run: |
          dart run ../bin/verify.dart \
            --release build/linux-release-artifacts/release.json \
            --require-signature
```

If GitHub Actions syntax rejects `env` in the job `if`, move the condition into a shell guard:

```bash
if [ "${LINUX_RELEASE_SIGNATURE_ENABLED:-}" != "true" ]; then
  echo "Skipping signed Linux release verification"
  exit 0
fi
```

- [ ] **Step 3: Verify local tests**

Run:

```bash
flutter test --no-pub test/linux_release_smoke_config_test.dart
```

Expected: pass.

---

### Task 5: Production Acceptance

- [ ] **Step 1: Run local Dart verification**

Run:

```bash
dart format --set-exit-if-changed .
flutter test --no-pub
flutter analyze --no-fatal-infos
dart pub publish --dry-run
```

Expected: format clean, tests pass, analyzer exits 0, dry-run exits 0.

- [ ] **Step 2: Push only after approval and wait for CI**

After explicit user approval:

```bash
git add .github/workflows/desktop-updater-ci.yml example/tool/updater_smoke.dart bin/verify.dart bin/sign_release.dart lib/src/core/artifact_verifier.dart lib/src/core/release_descriptor.dart lib/src/core/release_signature_verifier.dart pubspec.yaml pubspec.lock test/linux_release_smoke_config_test.dart test/release_signature_verifier_test.dart
git commit -m "feat: add linux release signature gates"
git push origin main
gh run watch --exit-status
```

Expected: Linux Debug and Release jobs pass. Signed descriptor gate is skipped until signature secrets are configured.

- [ ] **Step 3: Mark production readiness**

Linux can be marked:

```text
Linux release mechanics: ready after unsigned Release smoke passes.
Linux direct-zip production update: ready only after release.json signature verification, hosted artifact verification, release smoke, and rollback checks pass.
Linux Flatpak/Snap/repository distribution: use the store or repository update channel instead of this direct self-updater unless product requirements explicitly choose direct zip.
```

Do not call direct Linux production update ready while the signed descriptor gate is skipped.
