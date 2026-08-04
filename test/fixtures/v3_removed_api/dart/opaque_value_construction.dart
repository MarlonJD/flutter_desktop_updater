import "package:desktop_updater/src/core/update_client.dart";

void main() {
  final values = <Object? Function()>[
    () => UpdateCheckResult(
          index: null as dynamic,
          item: null as dynamic,
          descriptor: null as dynamic,
        ),
    () => UpdateStageResult(
          descriptor: null as dynamic,
          stagingPath: "/tmp/stage",
          stageProvenanceSha256: "a" * 64,
          stageProvenance: null as dynamic,
        ),
    () => RetainedVerifiedStage(
          stageRoot: "/tmp/root",
          stagingPath: "/tmp/stage",
          state: null as dynamic,
        ),
  ];
  assert(values.length == 3);
}
