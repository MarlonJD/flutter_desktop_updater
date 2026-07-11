import DesktopUpdaterKit
import Foundation

if CommandLine.arguments.count == 7,
   CommandLine.arguments[1] == "--schedule"
{
    let stagingParent = URL(fileURLWithPath: CommandLine.arguments[2])
    let verifiedApp = URL(fileURLWithPath: CommandLine.arguments[3])
    let packageID = CommandLine.arguments[4]
    let descriptorSHA256 = CommandLine.arguments[5]
    let artifactSHA256 = CommandLine.arguments[6]
    let stageRoot = try StageProvenance.createOwnedStage(parent: stagingParent)
    let stagedApp = stageRoot.appendingPathComponent(verifiedApp.lastPathComponent)
    try FileManager.default.copyItem(at: verifiedApp, to: stagedApp)
    let nonce = stageRoot.lastPathComponent.replacingOccurrences(
        of: updaterOwnedStagePrefix,
        with: ""
    )
    let provenance = try StageProvenance.write(
        stageRoot: stageRoot,
        nonce: nonce,
        packageID: packageID,
        descriptorSHA256: descriptorSHA256,
        artifactSHA256: artifactSHA256
    )
    let verifiedStage = MacVerifiedStage(
        stagedPath: stagedApp,
        stageRoot: stageRoot,
        provenance: provenance,
        artifactKind: "zip"
    )
    let request = MacInstallRequest(
        verifiedStage: verifiedStage,
        allowUnsignedUpdates: false,
        diagnosticsLogPath: nil
    )
    try MacInstallHelper().scheduleInstallAndRelaunch(request)
}

precondition(!DesktopUpdaterVersion.string.isEmpty)
print(
    "DesktopUpdaterKit \(DesktopUpdaterVersion.string) consumer compiled"
)
