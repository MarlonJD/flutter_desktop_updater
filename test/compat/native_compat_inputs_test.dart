import "dart:convert";
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
      final canonicalBytes = utf8.encode(
        utf8.decode(bytes).replaceAll("\r\n", "\n"),
      );
      expect(sha256.convert(canonicalBytes).toString(), fields[0]);
    }

    final result = await _compileProbe(root);
    expect(result.exitCode, 0, reason: "${result.stdout}\n${result.stderr}");

    final dotnet = await Process.run(
      "dotnet",
      <String>["build", "$root/dotnet-probe/PrepareV2Probe.csproj", "--nologo"],
      runInShell: false,
    );
    expect(dotnet.exitCode, 0, reason: "${dotnet.stdout}\n${dotnet.stderr}");
  });
}

Future<ProcessResult> _compileProbe(String root) {
  const clangArguments = <String>[
    "-std=c11",
    "-Werror",
  ];
  if (!Platform.isWindows) {
    return Process.run(
      "clang",
      <String>[
        ...clangArguments,
        "-I",
        root,
        "-fsyntax-only",
        "$root/prepare-v2-probe.c"
      ],
      runInShell: false,
    );
  }
  final msvc = _findMsvcCompiler();
  if (msvc == null) {
    return Process.run(
      "clang",
      <String>[
        ...clangArguments,
        "-I",
        root,
        "-fsyntax-only",
        "$root/prepare-v2-probe.c"
      ],
      runInShell: false,
    );
  }
  final msvcRoot = msvc.parent.parent.parent.parent.path;
  final sdkRoot = _findWindowsSdk();
  final arguments = <String>[
    "/nologo",
    "/TC",
    "/std:c11",
    "/W4",
    "/WX",
    "/Zs",
    "/I",
    "$msvcRoot\\include",
  ];
  if (sdkRoot != null) {
    for (final directory in const <String>["ucrt", "shared", "um", "winrt"]) {
      arguments.addAll(<String>["/I", "${sdkRoot.path}\\$directory"]);
    }
  }
  arguments.addAll(<String>["/I", root, "$root\\prepare-v2-probe.c"]);
  return Process.run(
    msvc.path,
    arguments,
    runInShell: false,
  );
}

File? _findMsvcCompiler() {
  final root = Directory(
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools"
    "\\VC\\Tools\\MSVC",
  );
  if (!root.existsSync()) return null;
  final candidates = root
      .listSync()
      .whereType<Directory>()
      .map(
        (directory) => File(
          "${directory.path}\\bin\\Hostx64\\x64\\cl.exe",
        ),
      )
      .where((file) => file.existsSync())
      .toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  return candidates.isEmpty ? null : candidates.last;
}

Directory? _findWindowsSdk() {
  final root = Directory("C:\\Program Files (x86)\\Windows Kits\\10\\Include");
  if (!root.existsSync()) return null;
  final candidates = root
      .listSync()
      .whereType<Directory>()
      .where(
        (directory) =>
            Directory("${directory.path}\\ucrt").existsSync() &&
            Directory("${directory.path}\\shared").existsSync(),
      )
      .toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  return candidates.isEmpty ? null : candidates.last;
}
