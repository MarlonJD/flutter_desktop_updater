import Foundation

// Conformance fixtures: diagnostics-redaction-cases.json and helper-events.json.
// Flutter lifecycle diagnostics remain Dart-owned. This preview records only
// native checks, download, verification, staging, and helper handoff evidence.

public enum RuntimeDiagnosticLevel: String, CaseIterable, Sendable {
    case info
    case warning
    case error
}

public enum RuntimeDiagnosticStage: String, CaseIterable, Sendable {
    case check
    case descriptor
    case policy
    case download
    case verify
    case stage
    case install
    case cleanup
}

public struct RuntimeDiagnosticEntry: Equatable, Sendable {
    public let timestamp: String
    public let stage: RuntimeDiagnosticStage
    public let level: RuntimeDiagnosticLevel
    public let message: String
    public let errorDescription: String?

    public init(
        timestamp: String,
        stage: RuntimeDiagnosticStage,
        level: RuntimeDiagnosticLevel,
        message: String,
        errorDescription: String? = nil
    ) {
        self.timestamp = timestamp
        self.stage = stage
        self.level = level
        self.message = message
        self.errorDescription = errorDescription
    }

    public func redactedLogLine() -> String {
        var line = "\(timestamp) \(level.rawValue) \(stage.rawValue): "
        line += redactRuntimeDiagnosticText(message)
        if let errorDescription {
            line += " Error: \(redactRuntimeDiagnosticText(errorDescription))"
        }
        return line
    }
}

public struct RuntimeDiagnosticsRecorder: Sendable {
    public static let maximumEntries = 80

    public private(set) var entries: [RuntimeDiagnosticEntry] = []
    public private(set) var omittedEntryCount = 0
    private let limit: Int

    public init(maximumEntries: Int = maximumEntries) {
        limit = max(1, maximumEntries)
    }

    public mutating func record(_ entry: RuntimeDiagnosticEntry) {
        if entries.count == limit {
            entries.removeFirst()
            omittedEntryCount += 1
        }
        entries.append(entry)
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        omittedEntryCount = 0
    }

    public func redactedLogLines() -> [String] {
        return entries.map { $0.redactedLogLine() }
    }
}

public typealias NativeHelperRecoveryEvent = MacHelperEvent

public struct HelperRecoverySummary: Equatable, Sendable {
    public let helperScheduled: Bool
    public let backupSucceeded: Bool
    public let installSucceeded: Bool
    public let rollbackAttempted: Bool
    public let backupRestored: Bool
    public let cleanupSucceeded: Bool
    public let relaunchAttempted: Bool

    public init(events: [String]) {
        let values = Set(events)
        helperScheduled = values.contains(MacHelperEvent.helperScheduled.rawValue)
        backupSucceeded = values.contains(MacHelperEvent.backupSuccess.rawValue)
        installSucceeded = values.contains(MacHelperEvent.moveSuccess.rawValue) &&
            !values.contains(MacHelperEvent.moveFailure.rawValue)
        rollbackAttempted = values.contains(MacHelperEvent.rollbackStart.rawValue)
        backupRestored = values.contains(MacHelperEvent.rollbackSuccess.rawValue)
        cleanupSucceeded = values.contains(MacHelperEvent.cleanupSuccess.rawValue)
        relaunchAttempted = values.contains(MacHelperEvent.relaunchAttempt.rawValue)
    }
}

private let runtimeAuthorizationPattern = try! NSRegularExpression(
    pattern: #"\b(authorization)\s*:\s*([^\r\n,;]+?)(?=\s+[A-Za-z0-9_-]*(?:token|signature|password|secret|credentials?|key)[A-Za-z0-9_-]*\s*[=:]|[\r\n,;]|$)"#,
    options: [.caseInsensitive]
)

private let runtimeSecretAssignmentPattern = try! NSRegularExpression(
    pattern: #"\b([A-Za-z0-9_-]*(?:token|signature|password|secret|authorization|credentials?|key)[A-Za-z0-9_-]*)\s*([=:])\s*([^&\s,;]+)"#,
    options: [.caseInsensitive]
)

func redactRuntimeDiagnosticText(_ input: String) -> String {
    let fullRange = NSRange(input.startIndex ..< input.endIndex, in: input)
    let withoutAuthorization = runtimeAuthorizationPattern
        .stringByReplacingMatches(
            in: input,
            range: fullRange,
            withTemplate: "$1: <redacted>"
        )
    let matches = runtimeSecretAssignmentPattern.matches(
        in: withoutAuthorization,
        range: NSRange(
            withoutAuthorization.startIndex ..< withoutAuthorization.endIndex,
            in: withoutAuthorization
        )
    )
    var redacted = withoutAuthorization
    for match in matches.reversed() {
        guard let range = Range(match.range, in: redacted),
              let keyRange = Range(match.range(at: 1), in: redacted),
              let separatorRange = Range(match.range(at: 2), in: redacted)
        else { continue }
        let key = redacted[keyRange]
        let separator = redacted[separatorRange]
        redacted.replaceSubrange(
            range,
            with: separator == ":"
                ? "\(key): <redacted>"
                : "\(key)=<redacted>"
        )
    }
    return redacted
}
