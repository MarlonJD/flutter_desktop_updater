import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  const root = "test/fixtures/compat/native-durable-state/2.7.0";
  const expectedFiles = <String>{
    "macos/directory-journal-schema1.json",
    "macos/verified-installer-journal-schema1.json",
    "macos/verified-installer-journal-schema2.json",
    "windows/persistent-record-schema3.json",
    "windows/portable-locator-schema1.json",
    "windows/protected-helper-endpoint-schema1.json",
    "windows/resolver-claim-schema1.json",
    "windows/transaction-journal-schema2.json",
    "linux/provider-journal-schema1.json",
    "linux/transaction-journal-schema2.json",
    "linux/transaction-registry-schema2.json",
  };

  test("frozen native durable-state bytes match their manifest", () async {
    final lines = await File("$root/SHA256SUMS").readAsLines();
    final observedFiles = <String>{};

    for (final line in lines) {
      final fields = line.split("  ");
      expect(fields, hasLength(2), reason: "Invalid manifest entry: $line");
      final hash = fields[0];
      final relativePath = fields[1];
      expect(hash, matches(RegExp(r"^[0-9a-f]{64}$")));
      expect(observedFiles.add(relativePath), isTrue);

      final bytes = await File("$root/$relativePath").readAsBytes();
      expect(
        sha256.convert(bytes).toString(),
        hash,
        reason: "Fixture bytes changed: $relativePath",
      );
    }

    expect(observedFiles, expectedFiles);
  });
}
