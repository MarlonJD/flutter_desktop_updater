import "package:desktop_updater/src/core/install_handoff.dart";
import "package:desktop_updater/src/core/update_client.dart";

abstract class ForgedCheckResult implements UpdateCheckResult {}

abstract class ForgedStageResult implements UpdateStageResult {}

abstract class ForgedRetainedStage implements RetainedVerifiedStage {}

abstract class ForgedPersistenceReceipt
    implements PersistedInstallTransaction {}
