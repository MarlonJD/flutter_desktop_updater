import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/update_recovery.dart";

void main() {
  PersistedInstallTransaction(throw UnimplementedError());
}

final class ForgedRequest implements VerifiedNativeInstallRequest {
  @override
  String get expectedArtifactSha256 => "a" * 64;

  @override
  String get expectedPackageId => "com.example.desktop";

  @override
  String get stageProvenanceSha256 => "b" * 64;

  @override
  String get stagingPath => "/tmp/stage";

  @override
  String get transactionId => "00000000-0000-4000-8000-000000000001";
}

NativeInstallTransactionStatus? keepImport(
        NativeInstallTransactionStatus? value) =>
    value;
