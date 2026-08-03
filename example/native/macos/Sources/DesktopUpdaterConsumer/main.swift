import DesktopUpdaterKit
import Foundation

if CommandLine.arguments.count == 3,
   CommandLine.arguments[1] == "--recover"
{
    let transactionID = CommandLine.arguments[2]
    let helper = MacInstallHelper()
    let status = try helper.queryTransaction(transactionID)
    if status.state == .prepared ||
        status.state == .commitAccepted ||
        status.state == .manualActionRequired
    {
        _ = try helper.recoverPendingInstall(transactionID)
    }
}

if CommandLine.arguments.count == 8,
   CommandLine.arguments[1] == "--prepare"
{
    let transactionID = CommandLine.arguments[2]
    let stageRoot = URL(fileURLWithPath: CommandLine.arguments[3])
    let stagedPath = URL(fileURLWithPath: CommandLine.arguments[4])
    let packageID = CommandLine.arguments[5]
    let keyID = CommandLine.arguments[6]
    guard let publicKey = Data(base64Encoded: CommandLine.arguments[7]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let verifiedStage = try MacVerifiedStage.loadAndVerify(
        stagedPath: stagedPath,
        stageRoot: stageRoot,
        expectedPackageID: packageID,
        trustedReleasePublicKeys: [keyID: publicKey]
    )
    let helper = MacInstallHelper()
    let reservation = try helper.prepareInstall(
        MacInstallRequest(verifiedStage: verifiedStage),
        transactionID: transactionID
    )
    _ = try helper.commitAfterExit(reservation)
}

if CommandLine.arguments.contains("--help") {
    print(
        "DesktopUpdaterConsumer [--recover TRANSACTION_ID] " +
            "[--prepare TRANSACTION_ID STAGE_ROOT STAGED_PATH " +
            "PACKAGE_ID KEY_ID PUBLIC_KEY_BASE64]"
    )
}

precondition(!DesktopUpdaterVersion.string.isEmpty)
print(
    "DesktopUpdaterKit \(DesktopUpdaterVersion.string) consumer compiled"
)
