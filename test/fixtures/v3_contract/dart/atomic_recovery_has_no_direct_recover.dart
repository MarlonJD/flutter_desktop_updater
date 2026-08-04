import "package:desktop_updater/desktop_updater_platform_interface.dart";
import "package:desktop_updater/src/core/update_recovery.dart";

Future<NativeInstallTransactionStatus?> _status(String id) async => null;

void main() {
  final recovery = AtomicAfterExitNativeInstallRecovery(
    query: _status,
    resolveAfterExit: _status,
  );
  recovery.recoverPendingInstallTransaction(
    "00000000-0000-4000-8000-000000000001",
  );
}
