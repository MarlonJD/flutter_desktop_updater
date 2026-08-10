import Cocoa
import Darwin
import FlutterMacOS
import ServiceManagement
@_spi(DesktopUpdaterSmoke) import desktop_updater
#if canImport(DesktopUpdaterKit)
@_spi(DesktopUpdaterSmoke) import DesktopUpdaterKit
#endif

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationDidFinishLaunching(_ notification: Notification) {
    SMAppServiceSmokeHost.runIfRequested(arguments: CommandLine.arguments)
    FlutterRecoverySmokeHost.runIfRequested(arguments: CommandLine.arguments)
    super.applicationDidFinishLaunching(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

private enum SMAppServiceSmokeHost {
  private static let command = "--desktop-updater-smappservice-smoke"
  private static let targetPath =
    "/Applications/Desktop Updater Smoke.app"
  private static let bundleIdentifier =
    "com.example.desktopUpdaterSmoke"
  private static let installAuthority = "authenticatedRootDaemon"

  static func runIfRequested(arguments: [String]) {
    guard let commandIndex = arguments.firstIndex(of: command) else {
      return
    }
    do {
      try validateInvocation()
      guard arguments.indices.contains(commandIndex + 1) else {
        throw SmokeError("Missing SMAppService smoke phase.")
      }
      switch arguments[commandIndex + 1] {
      case "register":
        try registerDaemon()
      case "prepareOnly":
        try prepare(arguments: arguments, commit: false)
      case "commit":
        try prepare(arguments: arguments, commit: true)
      case "recover":
        try persistentStatus(arguments: arguments, recover: true)
      case "query":
        try persistentStatus(arguments: arguments, recover: false)
      default:
        throw SmokeError("Unsupported SMAppService smoke phase.")
      }
    } catch {
      FileHandle.standardError.write(
        Data("SMAppService smoke failed: \(error)\n".utf8)
      )
      Darwin.exit(70)
    }
  }

  private static func registerDaemon() throws {
    guard #available(macOS 13.0, *),
          let plistName = Bundle.main.object(
            forInfoDictionaryKey:
              "DesktopUpdaterInstallHelperLaunchDaemonPlistName"
          ) as? String,
          !plistName.isEmpty else {
      throw SmokeError("SMAppService LaunchDaemon is unavailable.")
    }
    let service = SMAppService.daemon(plistName: plistName)
    switch service.status {
    case .notRegistered, .notFound:
      do {
        try service.register()
      } catch where service.status == .requiresApproval {
        // Registration succeeded, but the admin must approve the root daemon.
      }
    default:
      break
    }
    emitAndExit([
      "schemaVersion": 1,
      "mode": "privileged",
      "phase": "register",
      "serviceStatus": serviceStatusName(service.status),
      "targetPath": targetPath,
      "targetParentWritable": targetParentWritable(),
    ])
  }

  private static func prepare(arguments: [String], commit: Bool) throws {
    let stageRoot = URL(
      fileURLWithPath: try value("--stage-root", in: arguments),
      isDirectory: true
    ).standardizedFileURL
    let stagedApp = URL(
      fileURLWithPath: try value("--staged-app", in: arguments),
      isDirectory: true
    ).standardizedFileURL
    guard stagedApp.deletingLastPathComponent() == stageRoot else {
      throw SmokeError("Staged app is not a direct child of its stage root.")
    }
    guard let expectedPackageID = Bundle.main.bundleIdentifier else {
      throw SmokeError("Smoke host package identity is unavailable.")
    }
    let verifiedStage = try DesktopUpdaterPlugin.loadVerifiedStageForSmokeHost(
      stagedPath: stagedApp,
      stageRoot: stageRoot,
      expectedPackageID: expectedPackageID
    )
    let transactionID = UUID().uuidString.lowercased()
    let helper = try MacInstallHelper.smAppServiceSmokeHost()
    let reservation = try helper.prepareInstall(
      MacInstallRequest(verifiedStage: verifiedStage),
      transactionID: transactionID
    )
    var evidence: [String: Any] = [
      "schemaVersion": 1,
      "mode": "privileged",
      "phase": commit ? "commit" : "prepareOnly",
      "transactionId": reservation.transactionID,
      "helperEndpointIdentitySha256":
        reservation.helperEndpointIdentitySHA256,
      "privilegedDaemonExecuted": true,
      "authenticatedXPC": true,
      "installAuthority": installAuthority,
      "targetPath": targetPath,
      "targetParentWritable": targetParentWritable(),
    ]
    if commit {
      let status = try helper.commitAfterExit(reservation)
      guard status.state == .commitAccepted || status.state == .completed else {
        throw SmokeError("Privileged commit was not accepted.")
      }
      evidence["transactionState"] = stateName(status.state)
      evidence["commitAccepted"] = true
      if let gatePath = optionalValue("--exit-gate", in: arguments) {
        try emit(evidence)
        waitForGateAndExit(gatePath)
      }
    } else {
      // The recovery lane intentionally terminates the privileged daemon after
      // this process exits, then asks the restarted daemon to recover the
      // durable prepared transaction. Retain the reservation until process
      // exit so its deinitializer cannot cancel that transaction first.
      _ = Unmanaged.passRetained(reservation)
      evidence["transactionState"] = "prepared"
      evidence["reservationPreservedForRecovery"] = true
    }
    emitAndExit(evidence)
  }

  private static func persistentStatus(
    arguments: [String],
    recover: Bool
  ) throws {
    let transactionID = try value("--transaction-id", in: arguments)
    let helper = try MacInstallHelper.smAppServiceSmokeHost()
    let status =
      recover
      ? try helper.recoverPendingInstall(transactionID)
      : try helper.queryTransaction(transactionID)
    emitAndExit([
      "schemaVersion": 1,
      "mode": "privileged",
      "phase": recover ? "recover" : "query",
      "transactionId": transactionID,
      "transactionState": stateName(status.state),
      "resultCode": resultName(status.resultCode),
      "verifiedOutcome": status.detail,
      "helperEndpointIdentitySha256":
        status.helperEndpointIdentitySHA256,
      "privilegedDaemonExecuted": true,
      "authenticatedXPC": true,
      "installAuthority": installAuthority,
      "targetPath": targetPath,
      "recoveredSwap": recover && status.state == .rolledBack,
      "targetParentWritable": targetParentWritable(),
    ])
  }

  private static func targetParentWritable() -> Bool {
    // This is an observation, not an authorization gate. Admin-group ACLs can
    // legitimately make /Applications writable to the caller. The smoke
    // contract separately proves authenticated root-daemon execution.
    let parent = URL(fileURLWithPath: targetPath)
      .deletingLastPathComponent()
      .standardizedFileURL
    return parent.path.withCString { Darwin.access($0, W_OK) == 0 }
  }

  private static func validateInvocation() throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["DESKTOP_UPDATER_CONTROLLER_SMOKE"] == "1",
      environment["DESKTOP_UPDATER_CONTROLLER_SMOKE_TARGET"]
        == targetPath,
      Bundle.main.bundleIdentifier == bundleIdentifier,
      Bundle.main.bundleURL.standardizedFileURL.path == targetPath
    else {
      throw SmokeError("SMAppService smoke authority is unavailable.")
    }
  }

  private static func value(
    _ option: String,
    in arguments: [String]
  ) throws -> String {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1),
          !arguments[index + 1].isEmpty else {
      throw SmokeError("Missing SMAppService smoke option \(option).")
    }
    return arguments[index + 1]
  }

  private static func optionalValue(
    _ option: String,
    in arguments: [String]
  ) -> String? {
    guard let index = arguments.firstIndex(of: option),
          arguments.indices.contains(index + 1),
          !arguments[index + 1].isEmpty else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func stateName(_ state: InstallTransactionState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .prepared: return "prepared"
    case .commitAccepted: return "commitAccepted"
    case .completed: return "completed"
    case .cancelled: return "cancelled"
    case .expired: return "expired"
    case .rolledBack: return "rolledBack"
    case .manualActionRequired: return "manualActionRequired"
    @unknown default: return "unknown"
    }
  }

  private static func resultName(
    _ result: InstallTransactionResultCode
  ) -> String {
    switch result {
    case .none: return "none"
    case .accepted: return "accepted"
    case .succeeded: return "succeeded"
    case .rejected: return "rejected"
    case .endpointUnavailable: return "endpointUnavailable"
    case .authenticationFailed: return "authenticationFailed"
    case .invalidResponse: return "invalidResponse"
    case .recoveryRequired: return "recoveryRequired"
    @unknown default: return "none"
    }
  }

  @available(macOS 13.0, *)
  private static func serviceStatusName(
    _ status: SMAppService.Status
  ) -> String {
    switch status {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "notFound"
    }
  }

  private static func emitAndExit(_ evidence: [String: Any]) -> Never {
    do {
      try emit(evidence)
      Darwin.exit(0)
    } catch {
      FileHandle.standardError.write(
        Data("SMAppService smoke evidence failed: \(error)\n".utf8)
      )
      Darwin.exit(70)
    }
  }

  private static func emit(_ evidence: [String: Any]) throws {
    var data = try JSONSerialization.data(
      withJSONObject: evidence,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
  }

  private static func waitForGateAndExit(_ path: String) -> Never {
    let deadline = Date().addingTimeInterval(90)
    while Date() < deadline {
      if FileManager.default.fileExists(atPath: path) {
        Darwin.exit(0)
      }
      usleep(100_000)
    }
    FileHandle.standardError.write(
      Data("SMAppService smoke exit gate timed out.\n".utf8)
    )
    Darwin.exit(70)
  }

  private struct SmokeError: LocalizedError {
    let message: String

    init(_ message: String) {
      self.message = message
    }

    var errorDescription: String? { message }
  }
}

private enum FlutterRecoverySmokeHost {
  static func runIfRequested(arguments: [String]) {
    guard arguments.contains("--smoke") else { return }

    do {
      if arguments.contains("--probe-helper") || arguments.contains("--refresh-mismatched-helper") {
        let helper = try MacInstallHelper.smAppServiceSmokeHost()
        if arguments.contains("--refresh-mismatched-helper") {
          try helper.refreshMismatchedPrivilegedEndpointForSmoke()
        } else {
          try helper.refreshPrivilegedEndpointForSmoke()
        }
        try emit(["event": "helperProbe", "status": "healthy"])
        if arguments.contains("--hold-helper-active") {
          Thread.sleep(forTimeInterval: 15)
        }
        Darwin.exit(0)
      }

      if let transactionID = value("--recover-transaction", in: arguments) {
        try emitTransactionOutcome(
          "recovery",
          try MacInstallHelper.smAppServiceSmokeHost()
            .recoverPendingInstallForSmoke(transactionID)
        )
        Darwin.exit(0)
      }

      if let transactionID = value("--query-transaction", in: arguments) {
        try emitTransactionOutcome(
          "query",
          try MacInstallHelper.smAppServiceSmokeHost()
            .queryTransactionForSmoke(transactionID)
        )
        Darwin.exit(0)
      }

      if let transactionID = value(
        "--terminate-helper-for-recovery-smoke",
        in: arguments
      ) {
        let status = try MacInstallHelper.smAppServiceSmokeHost()
          .terminatePrivilegedHelperForRecoverySmoke(transactionID)
        try emit([
          "event": "helperCrashScheduled",
          "state": stateName(status.state),
          "resultCode": resultName(status.resultCode),
        ])
        Darwin.exit(0)
      }
    } catch {
      FileHandle.standardError.write(
        Data("Flutter recovery smoke failed.\n".utf8)
      )
      Darwin.exit(1)
    }
  }

  private static func value(
    _ option: String,
    in arguments: [String]
  ) -> String? {
    guard let index = arguments.firstIndex(of: option),
      arguments.indices.contains(index + 1),
      !arguments[index + 1].isEmpty
    else {
      return nil
    }
    return arguments[index + 1]
  }

  private static func emitTransactionOutcome(
    _ event: String,
    _ outcome: MacInstallSmokeTransactionOutcome
  ) throws {
    switch outcome {
    case .status(let status):
      try emit([
        "event": event,
        "state": stateName(status.state),
        "resultCode": resultName(status.resultCode),
      ])
    case .endpointUnavailable:
      try emit([
        "event": event,
        "state": "unknown",
        "resultCode": "endpointUnavailable",
      ])
    case .privilegedHelperApprovalRequired:
      try emit([
        "event": "installFailed",
        "code": "PrivilegedHelperApprovalRequired",
        "remediationActions": ["openMacOSBackgroundItemsSettings"],
      ])
    case .invalidResponse:
      throw SmokeError("Invalid native smoke response.")
    @unknown default:
      throw SmokeError("Unknown native smoke response.")
    }
  }

  private static func stateName(_ state: InstallTransactionState) -> String {
    switch state {
    case .unknown: return "unknown"
    case .prepared: return "prepared"
    case .commitAccepted: return "commitAccepted"
    case .completed: return "completed"
    case .cancelled: return "cancelled"
    case .expired: return "expired"
    case .rolledBack: return "rolledBack"
    case .manualActionRequired: return "manualActionRequired"
    @unknown default: return "unknown"
    }
  }

  private static func resultName(
    _ result: InstallTransactionResultCode
  ) -> String {
    switch result {
    case .none: return "none"
    case .accepted: return "accepted"
    case .succeeded: return "succeeded"
    case .rejected: return "rejected"
    case .endpointUnavailable: return "endpointUnavailable"
    case .authenticationFailed: return "authenticationFailed"
    case .invalidResponse: return "invalidResponse"
    case .recoveryRequired: return "recoveryRequired"
    @unknown default: return "none"
    }
  }

  private static func emit(_ value: [String: Any]) throws {
    var data = try JSONSerialization.data(
      withJSONObject: value,
      options: [.sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0a)
    FileHandle.standardOutput.write(data)
  }

  private struct SmokeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
