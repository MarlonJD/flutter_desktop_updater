import "dart:io";

import "package:flutter_test/flutter_test.dart";

void main() {
  test("shared transaction exposes exact durable states and bounded recovery",
      () {
    final header = File(
      "native_runtime/cpp/install_transaction.h",
    ).readAsStringSync();
    final source = File(
      "native_runtime/cpp/install_transaction.cc",
    ).readAsStringSync();

    for (final state in <String>[
      "kPrepared",
      "kBackupCreated",
      "kTargetActivated",
      "kCompleted",
    ]) {
      expect(header, contains(state), reason: state);
    }
    expect(header, contains("owner_process_start_token"));
    expect(header, contains("RecoverPendingInstall"));
    expect(source, contains("IsJournalOwnedPath"));
    expect(source, contains("transaction lock acquired"));
    expect(source, contains("transaction journal persisted"));
    expect(source, contains("recovery detected"));
    expect(source, contains("recovery restored backup"));
    expect(source, contains("recovery completed activation"));
  });

  test("Linux preflight is fd-relative and rejects nested mounts", () {
    final source = File(
      "linux/native/src/desktop_updater_native.cc",
    ).readAsStringSync();

    for (final primitive in <String>[
      "openat(",
      "O_NOFOLLOW",
      "fstatat(",
      "AT_SYMLINK_NOFOLLOW",
      "unlinkat(",
      "/proc/self/mountinfo",
      "st_dev",
    ]) {
      expect(source, contains(primitive), reason: primitive);
    }
    expect(source, contains("DecodeMountInfoPath"));
    expect(source, contains("RejectNestedMounts"));
    expect(source, isNot(contains(r'rm -rf "$target"')));
  });

  test("Windows traversal uses wide reparse-safe handles before mutation", () {
    final source = File(
      "windows/native/src/desktop_updater_native.cpp",
    ).readAsStringSync();

    expect(source, contains("CreateFileW"));
    expect(source, contains("FILE_FLAG_OPEN_REPARSE_POINT"));
    expect(source, contains("FILE_FLAG_BACKUP_SEMANTICS"));
    expect(source, contains("GetFileInformationByHandle"));
    expect(source, contains("ValidateTreeHasNoReparsePoints"));
    expect(source, contains("Test-NoReparseTree"));
    final recheck = source.indexOf(r"Test-NoReparseTree $targetRoot");
    final backup = source.indexOf("Write-DiagnosticsEvent 'backup start'");
    expect(recheck, isNonNegative);
    expect(backup, isNonNegative);
    expect(recheck, lessThan(backup));
  });

  test("macOS transaction stays SwiftPM-only and runtime floor stays 10.15",
      () {
    final package = File(
      "macos/desktop_updater/Package.swift",
    ).readAsStringSync();
    final podspec = File("macos/desktop_updater.podspec").readAsStringSync();
    final transaction = File(
      "macos/desktop_updater/Sources/DesktopUpdaterKit/InstallTransaction.swift",
    ).readAsStringSync();

    expect(package, contains('.macOS("10.15")'));
    expect(transaction, contains("backupCreated"));
    expect(transaction, contains("targetActivated"));
    expect(podspec, isNot(contains("InstallTransaction.swift")));
    expect(podspec, isNot(contains("Runtime/")));
    expect(RegExp(r"File\.join\(").allMatches(podspec), hasLength(5));
  });

  test("recovery diagnostics are documented without canonical user paths", () {
    final docs = File(
      "docs/diagnostics-and-recovery.md",
    ).readAsStringSync();
    for (final event in <String>[
      "transaction lock acquired",
      "transaction journal persisted",
      "recovery detected",
      "recovery restored backup",
      "recovery completed activation",
    ]) {
      expect(docs, contains(event), reason: event);
    }
    expect(docs, contains("canonical paths are redacted"));
  });
}
