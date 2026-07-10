import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("preview documentation publishes implemented APIs with literal evidence",
      () {
    final docs = readRequiredFile("docs/native-runtime-api.md");

    for (final capability in <String>[
      "| macOS | `zip` |",
      "| macOS | `dmg` |",
      "| macOS | `pkgInstaller` |",
      "| Windows | `zip` |",
      "| Windows | `innoInstaller` |",
      "| Linux | `zip` |",
    ]) {
      expect(docs, contains(capability));
    }
    for (final operation in <String>[
      "checkForUpdate",
      "downloadVerifyAndStage",
      "installAndRelaunch",
    ]) {
      expect(docs, contains(operation));
    }
    expect(docs, contains("source-first"));
    expect(docs, contains("4 MiB"));
    expect(docs, contains("100,000"));
    expect(docs, contains("8 GiB"));
    expect(docs, contains("4 GiB"));
    expect(docs, contains("not production-ready"));
    expect(docs, contains("candidate-only"));
    expect(docs, contains("not run"));
    expect(docs, isNot(contains("`not implemented`")));
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
    final client = readRequiredFile(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/Runtime/UpdateClient.swift",
    );

    expect(api, contains("public struct RuntimeConfiguration"));
    expect(api, contains("public enum RuntimeOutcome"));
    expect(api, contains("case packageIdentityMismatch"));
    expect(api, contains("case unsupportedArtifactKind"));
    expect(api, contains("maximumMetadataBytes: Int64 = 4 * 1024 * 1024"));
    expect(api, contains("guard maximumMetadataBytes > 0"));
    expect(client, contains("public final class UpdateClient"));
    expect(client, contains("supportPolicyStatus"));
    expect(sample, contains("try RuntimeConfiguration("));
    expect(sample, contains("RuntimeOutcome.noUpdate"));
    expect(manifest, contains("DESKTOP_UPDATER_PACKAGE_PATH"));
    expect(
      manifest,
      contains('.package(name: "flutter_desktop_updater", path: packagePath)'),
    );
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
    expect(
      header,
      contains("desktop_updater_runtime_client_check_for_update_v1"),
    );
    expect(
      header,
      contains("desktop_updater_runtime_client_download_verify_and_stage_v1"),
    );
    expect(
      header,
      contains("desktop_updater_runtime_client_install_and_relaunch_v1"),
    );
    expect(header, contains('extern "C"'));
    expect(source, contains("catch (...)"));
    expect(cmake, contains("option(DESKTOP_UPDATER_NATIVE_RUNTIME"));
    expect(cmake, contains("desktop_updater_runtime_c.cpp"));
    expect(dotnet, contains("public sealed class DesktopUpdaterConfiguration"));
    expect(dotnet, contains("public enum DesktopUpdaterOutcome"));
    expect(dotnet, contains("public sealed class DesktopUpdaterClient"));
    expect(dotnet, contains("SupportPolicyStatus"));
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
    expect(header, contains("class UpdateClient"));
    expect(header, contains("support_policy_status"));
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
