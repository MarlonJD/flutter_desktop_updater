import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("preview documentation publishes only not-implemented API contracts",
      () {
    final docs = readRequiredFile("docs/native-runtime-api.md");

    for (final capability in <String>[
      "macOS | `zip` | `not implemented`",
      "macOS | `dmg` | `not implemented`",
      "macOS | `pkgInstaller` | `not implemented`",
      "Windows | `zip` | `not implemented`",
      "Windows | `innoInstaller` | `not implemented`",
      "Linux | `zip` | `not implemented`",
    ]) {
      expect(docs, contains(capability));
    }
    expect(docs, contains("source ABI only"));
    expect(docs, contains("4 MiB"));
    expect(docs, contains("100,000"));
    expect(docs, contains("8 GiB"));
    expect(docs, contains("4 GiB"));
    expect(docs, isNot(contains("production-ready")));
  });

  test("Swift runtime API exposes validated configuration and typed outcomes",
      () {
    final api = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/"
      "RuntimeError.swift",
    );
    final sample = readRequiredFile(
      "example/native/macos-runtime/Sources/MacOSRuntimeCompile/main.swift",
    );
    final manifest =
        readRequiredFile("example/native/macos-runtime/Package.swift");

    expect(api, contains("public struct RuntimeConfiguration"));
    expect(api, contains("public enum RuntimeOutcome"));
    expect(api, contains("case packageIdentityMismatch"));
    expect(api, contains("case unsupportedArtifactKind"));
    expect(api, contains("maximumMetadataBytes: Int64 = 4 * 1024 * 1024"));
    expect(api, contains("guard maximumMetadataBytes > 0"));
    expect(sample, contains("try RuntimeConfiguration("));
    expect(sample, contains("RuntimeOutcome.noUpdate"));
    expect(manifest, contains('.package(path: "../../..")'));
    expect("$manifest\n$sample", isNot(contains("Flutter")));
  });

  test("Windows runtime C ABI is versioned, sized, owned, and exception-safe",
      () {
    final header = readRequiredFile(
      "windows/native/include/desktop_updater_runtime_c.h",
    );
    final source = readRequiredFile(
      "windows/native/src/runtime/desktop_updater_runtime_c.cpp",
    );
    final cmake = readRequiredFile("windows/native/CMakeLists.txt");
    final dotnet = readRequiredFile(
      "windows/native/dotnet/DesktopUpdater.Native/DesktopUpdaterClient.cs",
    );
    final sample = readRequiredFile(
      "example/native/windows-dotnet-runtime/Program.cs",
    );

    expect(header, contains("DESKTOP_UPDATER_RUNTIME_ABI_VERSION 1u"));
    expect(header, contains("desktop_updater_runtime_configuration_v1"));
    expect(header, contains("uint32_t abi_version"));
    expect(header, contains("size_t struct_size"));
    expect(header, contains("desktop_updater_runtime_client_free_v1"));
    expect(header, contains("desktop_updater_runtime_result_free_v1"));
    expect(header, contains('extern "C"'));
    expect(source, contains("catch (...)"));
    expect(cmake, contains("option(DESKTOP_UPDATER_NATIVE_RUNTIME"));
    expect(cmake, contains("desktop_updater_runtime_c.cpp"));
    expect(dotnet, contains("public sealed class DesktopUpdaterConfiguration"));
    expect(dotnet, contains("public enum DesktopUpdaterOutcome"));
    expect(dotnet, contains("MaximumMetadataBytes"));
    expect(sample, contains("new DesktopUpdaterConfiguration("));
    expect(sample, contains("DesktopUpdaterOutcome.NoUpdate"));
    expect(sample, isNot(contains("DllImport")));
  });

  test("Linux runtime API remains a source-only C++ contract", () {
    final header = readRequiredFile(
      "linux/native/include/desktop_updater_runtime.h",
    );
    final source = readRequiredFile(
      "example/native/linux-cmake-runtime/main.cpp",
    );
    final cmake =
        readRequiredFile("example/native/linux-cmake-runtime/CMakeLists.txt");

    expect(header, contains("struct RuntimeConfiguration"));
    expect(header, contains("enum class RuntimeOutcome"));
    expect(header, contains("kPackageIdentityMismatch"));
    expect(header, contains("kUnsupportedArtifactKind"));
    expect(header, contains("std::function"));
    expect(header, isNot(contains("extern \"C\"")));
    expect(source, contains("desktop_updater_runtime.h"));
    expect(source, contains("RuntimeOutcome::kNoUpdate"));
    expect(source, isNot(contains("Flutter")));
    expect(cmake, contains("find_package(desktop_updater_native"));
    expect(cmake, contains("desktop_updater::native"));
  });
}

String readRequiredFile(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: "$path must exist");
  return file.existsSync() ? file.readAsStringSync() : "";
}
