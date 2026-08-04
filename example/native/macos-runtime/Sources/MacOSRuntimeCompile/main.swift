@_spi(DesktopUpdaterSmoke) import DesktopUpdaterKit
import Darwin
import Foundation

@main
struct MacOSRuntimeSmoke {
    static func main() async {
        do {
            try await run()
        } catch {
            emitSanitizedFailure()
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = try Arguments(CommandLine.arguments)
        if arguments.has("--probe-helper") ||
            arguments.has("--refresh-mismatched-helper")
        {
            let helper = MacInstallHelper.smAppServiceSmokeHost()
            if arguments.has("--refresh-mismatched-helper") {
                try helper.refreshMismatchedPrivilegedEndpointForSmoke()
            } else {
                try helper.refreshPrivilegedEndpointForSmoke()
            }
            try emit([
                "event": "helperProbe",
                "status": "healthy",
            ])
            if arguments.has("--hold-helper-active") {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            }
            return
        }
        if let transactionID = arguments.optionalValue(
            "--recover-transaction"
        ) {
            let outcome = MacInstallHelper()
                .recoverPendingInstallForSmoke(transactionID)
            try emitTransactionOutcome("recovery", outcome)
            return
        }
        if let transactionID = arguments.optionalValue(
            "--terminate-helper-for-recovery-smoke"
        ) {
            let status = try MacInstallHelper()
                .terminatePrivilegedHelperForRecoverySmoke(transactionID)
            try emit([
                "event": "helperCrashScheduled",
                "state": recoveryStateName(status.state),
                "resultCode": recoveryResultName(status.resultCode),
            ])
            return
        }
        if let transactionID = arguments.optionalValue(
            "--query-transaction"
        ) {
            let outcome = MacInstallHelper()
                .queryTransactionForSmoke(transactionID)
            try emitTransactionOutcome("query", outcome)
            return
        }
        guard arguments.isSmoke else {
            let configuration = try RuntimeConfiguration(
                appArchiveUrl: URL(
                    string: "https://updates.example.test/app-archive.json"
                )!,
                expectedPackageId: "com.example.native-runtime-smoke",
                currentVersion: "2.7.0",
                currentBuildNumber: 270,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                installationIdentity: "external-swiftpm-consumer",
                pinnedPublicKeysById: [
                    "native-runtime-smoke-stable": Data(repeating: 1, count: 32)
                ]
            )
            let client = UpdateClient(configuration: configuration)
            print(
                "DesktopUpdaterKit runtime API compiled: " +
                    RuntimeOutcome.noUpdate.rawValue +
                    " via \(type(of: client))"
            )
            return
        }

        let publicKey = try requiredData(
            base64: arguments.value("--public-key-base64")
        )
        let packageId = arguments.value("--package-id")
        let smokeRoot = URL(
            fileURLWithPath: arguments.value("--smoke-root"),
            isDirectory: true
        )
        let transactionID = arguments.value("--transaction-id")
        let configuration = try RuntimeConfiguration(
            appArchiveUrl: try requiredURL(
                arguments.value("--app-archive-url")
            ),
            expectedPackageId: packageId,
            currentVersion: arguments.optionalValue("--current-version") ?? "2.7.0",
            currentBuildNumber: arguments.optionalInt("--current-build-number") ?? 270,
            currentUpdaterVersion: "2.7.0",
            platform: "macos",
            installationIdentity: "macos-native-runtime-smoke",
            pinnedPublicKeysById: [
                "native-runtime-smoke-stable": publicKey
            ]
        )
        let client = UpdateClient(configuration: configuration)
        let check = await client.checkForUpdate()
        guard check.outcome == .updateAvailable else {
            throw SmokeFailure("checkForUpdate: \(check.outcome.rawValue) \(check.message)")
        }
        let staged = try await client.downloadVerifyAndStage(
            check,
            downloadDirectory: smokeRoot.appendingPathComponent("downloads"),
            stagingRoot: smokeRoot.appendingPathComponent("staging"),
            expectedTeamIdentifier: arguments.optionalValue(
                "--expected-team-identifier"
            ) ?? ""
        ).get()
        try writeDiagnostics(
            client.diagnostics.redactedLogLines(),
            to: smokeRoot.appendingPathComponent("runtime-diagnostics.log")
        )
        do {
            let reservation = try client.prepareInstall(
                staged,
                transactionID: transactionID
            )
            _ = try client.commitAfterExit(reservation)
        } catch let RuntimeError.diagnostic(outcome, diagnostic)
            where arguments.expectsHelperApprovalRequirement &&
            outcome == .installHandoffFailure &&
            diagnostic.code == .privilegedHelperApprovalRequired &&
            diagnostic.remediationActions.contains(
                .openMacOSBackgroundItemsSettings
            )
        {
            try emit([
                "event": "installFailed",
                "code": diagnostic.code.rawValue,
                "remediationActions": diagnostic.remediationActions.map(\.rawValue),
            ])
            print("Expected SMAppService admin approval requirement")
            return
        }
        if arguments.expectsHelperApprovalRequirement {
            print("SMAppService helper unexpectedly avoided approval.")
            return
        }
        print(
            "prepareInstall committed \(staged.descriptor.version) " +
                "from \(staged.descriptor.artifact.kind)"
        )
    }
}

private struct Arguments {
    private let values: [String]

    init(_ values: [String]) throws {
        self.values = values
        let operationCount = [
            optionalValue("--recover-transaction") != nil,
            optionalValue("--query-transaction") != nil,
            optionalValue("--terminate-helper-for-recovery-smoke") != nil,
            has("--probe-helper"),
            has("--refresh-mismatched-helper"),
        ].filter { $0 }.count
        guard operationCount <= 1 else {
            throw SmokeFailure("Select exactly one transaction operation.")
        }
        if has("--hold-helper-active") &&
            !has("--probe-helper") &&
            !has("--refresh-mismatched-helper")
        {
            throw SmokeFailure(
                "Helper hold is available only for helper probes."
            )
        }
        if optionalValue("--recover-transaction") != nil ||
            optionalValue("--query-transaction") != nil ||
            optionalValue("--terminate-helper-for-recovery-smoke") != nil ||
            has("--probe-helper") ||
            has("--refresh-mismatched-helper")
        {
            guard isSmoke else {
                throw SmokeFailure("Transaction inspection is available only in smoke mode.")
            }
            return
        }
        if isSmoke {
            for option in [
                "--app-archive-url",
                "--public-key-base64",
                "--package-id",
                "--smoke-root",
                "--transaction-id",
            ] where optionalValue(option) == nil {
                throw SmokeFailure("Missing required argument \(option).")
            }
            if let build = optionalValue("--current-build-number"),
               Int64(build).map({ $0 >= 0 }) != true {
                throw SmokeFailure("Current build number must be non-negative.")
            }
        }
    }

    var isSmoke: Bool { values.contains("--smoke") }
    var expectsHelperApprovalRequirement: Bool {
        values.contains("--expect-helper-approval-required")
    }
    func has(_ option: String) -> Bool { values.contains(option) }

    func value(_ option: String) -> String {
        optionalValue(option)!
    }

    func optionalValue(_ option: String) -> String? {
        guard let index = values.firstIndex(of: option),
              values.indices.contains(index + 1)
        else { return nil }
        return values[index + 1]
    }

    func optionalInt(_ option: String) -> Int64? {
        optionalValue(option).flatMap(Int64.init)
    }
}

private func recoveryStateName(_ state: InstallTransactionState) -> String {
    switch state {
    case .unknown: "unknown"
    case .prepared: "prepared"
    case .commitAccepted: "commitAccepted"
    case .completed: "completed"
    case .cancelled: "cancelled"
    case .expired: "expired"
    case .rolledBack: "rolledBack"
    case .manualActionRequired: "manualActionRequired"
    @unknown default: "unknown"
    }
}

private func recoveryResultName(
    _ result: InstallTransactionResultCode
) -> String {
    switch result {
    case .none: "none"
    case .accepted: "accepted"
    case .succeeded: "succeeded"
    case .rejected: "rejected"
    case .endpointUnavailable: "endpointUnavailable"
    case .authenticationFailed: "authenticationFailed"
    case .invalidResponse: "invalidResponse"
    case .recoveryRequired: "recoveryRequired"
    @unknown default: "invalidResponse"
    }
}

private func emitTransactionOutcome(
    _ event: String,
    _ outcome: MacInstallSmokeTransactionOutcome
) throws {
    switch outcome {
    case let .status(status):
        try emit([
            "event": event,
            "state": recoveryStateName(status.state),
            "resultCode": recoveryResultName(status.resultCode),
        ])
    case .endpointUnavailable:
        try emit([
            "event": event,
            "state": "unknown",
            "resultCode": "endpointUnavailable",
        ])
    case .privilegedHelperApprovalRequired:
        let diagnostic = RuntimeDiagnostic(
            code: .privilegedHelperApprovalRequired,
            message: "Administrator approval is required before the privileged macOS updater helper can run.",
            remediationActions: [.openMacOSBackgroundItemsSettings]
        )
        try emit([
            "event": "installFailed",
            "code": diagnostic.code.rawValue,
            "remediationActions": diagnostic.remediationActions.map(\.rawValue),
        ])
    case .invalidResponse:
        emitSanitizedFailure()
        Darwin.exit(EXIT_FAILURE)
    @unknown default:
        emitSanitizedFailure()
        Darwin.exit(EXIT_FAILURE)
    }
}

private func emitSanitizedFailure() {
    print(#"{"event":"smokeFailed","status":"failed"}"#)
}

private struct SmokeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func requiredURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme != nil else {
        throw SmokeFailure("Smoke app-archive URL must be absolute.")
    }
    return url
}

private func requiredData(base64: String) throws -> Data {
    guard let data = Data(base64Encoded: base64), data.count == 32 else {
        throw SmokeFailure("Smoke Ed25519 public key must contain 32 bytes.")
    }
    return data
}

private func writeDiagnostics(_ lines: [String], to file: URL) throws {
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try (lines.joined(separator: "\n") + "\n").write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
}

private func emit(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    guard let line = String(data: data, encoding: .utf8) else {
        throw SmokeFailure("Smoke JSON event could not be encoded as UTF-8.")
    }
    print(line)
}
