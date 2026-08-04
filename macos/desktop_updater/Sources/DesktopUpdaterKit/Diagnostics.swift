import Foundation

public struct MacDiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: String
    public let event: String

    public init(timestamp: String, event: String) {
        self.timestamp = timestamp
        self.event = event
    }
}

public enum MacHelperEvent: String, CaseIterable, Sendable {
    case helperScheduled = "helper scheduled"
    case waitingForParentProcess = "waiting for parent process"
    case parentProcessExited = "parent process exited"
    case stagingPathValidation = "staging path validation"
    case backupStart = "backup start"
    case backupSuccess = "backup success"
    case backupFailure = "backup failure"
    case moveStart = "move start"
    case moveSuccess = "move success"
    case moveFailure = "move failure"
    case rollbackStart = "rollback start"
    case rollbackSuccess = "rollback success"
    case rollbackFailure = "rollback failure"
    case cleanupStart = "cleanup start"
    case cleanupSuccess = "cleanup success"
    case cleanupFailure = "cleanup failure"
    case relaunchAttempt = "relaunch attempt"
}
