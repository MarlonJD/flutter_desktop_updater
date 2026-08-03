import "dart:io";

import "package:crypto/crypto.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  const root = "test/fixtures/compat/windows-native-abi/2.7.0";

  test("frozen 2.7 Windows ABI input provenance, hashes, and compiles",
      () async {
    final readme = await File("$root/README.md").readAsString();
    expect(
      readme,
      contains("2f91208f0de95b9656b0ce2a28258e70a2920b86"),
      reason: "The frozen ABI fixtures need named baseline provenance.",
    );
    for (final name in const <String>[
      "desktop_updater_native_c.h",
      "desktop_updater_version.h",
      "prepare-v2-probe.c",
      "dotnet-probe/PrepareV2Probe.csproj",
      "dotnet-probe/Program.cs",
    ]) {
      expect(readme, contains(name));
    }

    final sums = await File("$root/SHA256SUMS").readAsLines();
    for (final line in sums) {
      final fields = line.split("  ");
      expect(fields, hasLength(2));
      final bytes = await File("$root/${fields[1]}").readAsBytes();
      expect(sha256.convert(bytes).toString(), fields[0]);
    }

    final result = await Process.run(
      "clang",
      <String>[
        "-std=c11",
        "-Werror",
        "-I",
        root,
        "-fsyntax-only",
        "$root/prepare-v2-probe.c",
      ],
      runInShell: false,
    );
    expect(result.exitCode, 0, reason: "${result.stdout}\n${result.stderr}");

    final dotnet = await Process.run(
      "dotnet",
      <String>["build", "$root/dotnet-probe/PrepareV2Probe.csproj", "--nologo"],
      runInShell: false,
    );
    expect(dotnet.exitCode, 0, reason: "${dotnet.stdout}\n${dotnet.stderr}");
  });
}
