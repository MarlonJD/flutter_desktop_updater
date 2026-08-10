import Darwin
import Foundation
import OSLog

/// Stable, non-sensitive lifecycle events emitted by the macOS install helper.
///
/// The transaction journal remains the authority for recovery. These events are
/// support evidence only and are deliberately best-effort.
enum MacHelperEvent: String, CaseIterable, Codable, Sendable {
    case helperScheduled = "helper scheduled"
    case requestRejected = "request rejected"
    case waitingForParentProcess = "waiting for parent process"
    case parentProcessExited = "parent process exited"
    case stagingPathValidation = "staging path validation"
    case backupStart = "backup start"
    case backupSuccess = "backup success"
    case backupFailure = "backup failure"
    case moveStart = "move start"
    case moveSuccess = "move success"
    case moveFailure = "move failure"
    case managerStarted = "manager started"
    case verificationPending = "verification pending"
    case verificationSuccess = "verification success"
    case verificationFailure = "verification failure"
    case rollbackStart = "rollback start"
    case rollbackSuccess = "rollback success"
    case rollbackFailure = "rollback failure"
    case cleanupStart = "cleanup start"
    case cleanupSuccess = "cleanup success"
    case cleanupFailure = "cleanup failure"
    case recoveryMarkerCleared = "recovery marker cleared"
    case recoveryRequired = "recovery required"
    case recoveryStart = "recovery start"
    case recoverySuccess = "recovery success"
    case recoveryFailure = "recovery failure"
}

struct MacHelperDiagnosticEvent: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let sequence: UInt64
    let timestampUnixMilliseconds: Int64
    let transactionID: String?
    let event: MacHelperEvent
    let state: String
    let resultCode: String
    let detailCode: String

    init(
        sequence: UInt64,
        timestampUnixMilliseconds: Int64,
        transactionID: String?,
        event: MacHelperEvent,
        state: String,
        resultCode: String,
        detailCode: String
    ) {
        schemaVersion = Self.schemaVersion
        self.sequence = sequence
        self.timestampUnixMilliseconds = timestampUnixMilliseconds
        self.transactionID = transactionID
        self.event = event
        self.state = state
        self.resultCode = resultCode
        self.detailCode = detailCode
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sequence
        case timestampUnixMilliseconds
        case transactionID = "transactionId"
        case event
        case state
        case resultCode
        case detailCode
    }
}

/// Converts helper failures to a bounded, non-sensitive diagnostics code.
///
/// Error descriptions are intentionally not persisted: some Foundation errors
/// can contain paths or other caller-controlled text. Protocol errors expose
/// only their stable validation code; all other known enum failures expose
/// their case name, and unknown errors expose only their type name.
func macHelperSafeErrorCode(_ error: Error) -> String {
    let raw: String
    if let protocolError = error as? NativeInstallProtocolError {
        raw = "protocol.\(protocolError.code)"
    } else if error is MacOneShotAuthorizationError
        || error is MacOneShotInstallError
        || error is MacOneShotWireError
        || error is MacPrivilegedTransactionHandlerError
        || error is MacFileTransactionError
        || error is MacVerifiedInstallerProtectedStageError
        || error is MacVerifiedInstallerHandoffError
        || error is MacInstallerWorkerError
        || error is MacPersistentRecoveryError
        || error is MacPersistentRecoveryWireError
        || error is MacSealedInstallPolicyError
        || error is MacPrivilegeError
    {
        raw = String(describing: error)
    } else {
        raw = String(describing: type(of: error))
    }
    let sanitized = raw.map { character in
        character.isNumber || character.isLetter || character == "."
            || character == "_" || character == "-"
            ? character : "_"
    }
    let result = String(sanitized.prefix(64))
    return result.isEmpty ? "unknown" : result
}

func macHelperSafeOperationCode(_ operation: String) -> String {
    let sanitized = operation.map { character in
        character.isNumber || character.isLetter || character == "."
            || character == "_" || character == "-"
            ? character : "_"
    }
    let result = String(sanitized.prefix(32))
    return result.isEmpty ? "unknown" : result
}

protocol MacHelperDiagnosticsRecording: AnyObject {
    func configure(
        destination: NativeInstallDiagnosticsDestinationV1?
    )

    func record(
        _ event: MacHelperEvent,
        transactionID: String?,
        state: String,
        resultCode: String,
        detailCode: String
    )
}

final class NoMacHelperDiagnosticsRecorder: MacHelperDiagnosticsRecording {
    func configure(destination: NativeInstallDiagnosticsDestinationV1?) {}

    func record(
        _ event: MacHelperEvent,
        transactionID: String? = nil,
        state: String = "unknown",
        resultCode: String = "none",
        detailCode: String = "none"
    ) {}
}

final class MacHelperDiagnosticsRecorder: MacHelperDiagnosticsRecording,
    @unchecked Sendable
{
    static var defaultLogURL: URL {
        if Darwin.geteuid() == 0 {
            return URL(
                fileURLWithPath: "/Library/Logs/DesktopUpdater/events.jsonl"
            )
        }
        let libraryURL = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return libraryURL.appendingPathComponent(
            "Logs/DesktopUpdater/events.jsonl"
        )
    }
    static let maximumFileBytes = 512 * 1024
    private static let processFileLock = NSLock()

    private let logURL: URL
    private let maximumFileBytes: Int
    private let lock = NSLock()
    private var nextSequence: UInt64 = 1
    private var writesToInheritedStandardError = false

    init(
        logURL: URL = MacHelperDiagnosticsRecorder.defaultLogURL,
        maximumFileBytes: Int = MacHelperDiagnosticsRecorder.maximumFileBytes
    ) {
        self.logURL = logURL.standardizedFileURL
        self.maximumFileBytes = max(4_096, maximumFileBytes)
    }

    func configure(destination: NativeInstallDiagnosticsDestinationV1?) {
        lock.lock()
        writesToInheritedStandardError = destination?.kind == "inheritedStream"
            && destination?.stream == "stderr"
        lock.unlock()
    }

    func record(
        _ event: MacHelperEvent,
        transactionID: String? = nil,
        state: String = "unknown",
        resultCode: String = "none",
        detailCode: String = "none"
    ) {
        let safeTransactionID = Self.safeTransactionID(transactionID)
        let timestamp = Int64(
            (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        )
        let safeState = Self.safeCode(state)
        let safeResultCode = Self.safeCode(resultCode)
        let safeDetailCode = Self.safeCode(detailCode)
        let value = appendJSONLine { sequence in
            MacHelperDiagnosticEvent(
                sequence: sequence,
                timestampUnixMilliseconds: timestamp,
                transactionID: safeTransactionID,
                event: event,
                state: safeState,
                resultCode: safeResultCode,
                detailCode: safeDetailCode
            )
        } ?? makeFallbackEvent(
            transactionID: safeTransactionID,
            event: event,
            timestampUnixMilliseconds: timestamp,
            state: safeState,
            resultCode: safeResultCode,
            detailCode: safeDetailCode
        )

        if #available(macOS 11.0, *) {
            let logger = Logger(
                subsystem: "com.desktop-updater.install-helper",
                category: "diagnostics"
            )
            let transactionText = safeTransactionID ?? "none"
            let message = "\(event.rawValue) transactionId=\(transactionText) " +
                "state=\(value.state) result=\(value.resultCode) " +
                "detail=\(value.detailCode) sequence=\(value.sequence)"
            logger.info("\(message, privacy: .public)")
        }

        guard writesToStderr() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(value) else { return }
        line.append(0x0a)
        FileHandle.standardError.write(line)
    }

    private func makeFallbackEvent(
        transactionID: String?,
        event: MacHelperEvent,
        timestampUnixMilliseconds: Int64,
        state: String,
        resultCode: String,
        detailCode: String
    ) -> MacHelperDiagnosticEvent {
        lock.lock()
        let sequence = nextSequence
        nextSequence += 1
        lock.unlock()
        return MacHelperDiagnosticEvent(
            sequence: sequence,
            timestampUnixMilliseconds: timestampUnixMilliseconds,
            transactionID: transactionID,
            event: event,
            state: state,
            resultCode: resultCode,
            detailCode: detailCode
        )
    }

    private func writesToStderr() -> Bool {
        lock.lock()
        let value = writesToInheritedStandardError
        lock.unlock()
        return value
    }

    private func appendJSONLine(
        _ makeEvent: (UInt64) -> MacHelperDiagnosticEvent
    ) -> MacHelperDiagnosticEvent? {
        lock.lock()
        defer { lock.unlock() }
        Self.processFileLock.lock()
        defer { Self.processFileLock.unlock() }

        let directoryURL = logURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        guard Self.isOwnedPrivateDirectory(directoryURL.path) else {
            return nil
        }

        let descriptor = logURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { _ = Darwin.close(descriptor) }
        guard Self.acquireFileLock(descriptor) else { return nil }
        defer { Self.releaseFileLock(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_uid == Darwin.geteuid() else {
            return nil
        }
        _ = Darwin.fchmod(descriptor, mode_t(0o600))
        let fileSequence = Self.latestSequence(
            descriptor: descriptor,
            maximumBytes: maximumFileBytes
        )
        let sequence = max(nextSequence, fileSequence + 1)
        let value = makeEvent(sequence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        if status.st_size + Int64(data.count) + 1
            > Int64(maximumFileBytes) {
            guard Darwin.ftruncate(descriptor, 0) == 0 else { return nil }
        }

        var line = data
        line.append(0x0a)
        let wrote = line.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrote else { return nil }
        _ = Darwin.fsync(descriptor)
        nextSequence = sequence + 1
        return value
    }

    private static func acquireFileLock(_ descriptor: Int32) -> Bool {
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: Darwin.getpid(),
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        for attempt in 0 ..< 4 {
            if fcntl(descriptor, F_SETLK, &lock) == 0 {
                return true
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                return false
            }
            if attempt < 3 {
                usleep(1_000)
            }
        }
        return false
    }

    private static func releaseFileLock(_ descriptor: Int32) {
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: Darwin.getpid(),
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = fcntl(descriptor, F_SETLK, &lock)
    }

    private static func latestSequence(
        descriptor: Int32,
        maximumBytes: Int
    ) -> UInt64 {
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0 else { return 0 }
        let offset = max(
            Int64(0),
            fileStatus.st_size - Int64(maximumBytes)
        )
        guard Darwin.lseek(descriptor, offset, SEEK_SET) >= 0 else {
            return 0
        }
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        let count = bytes.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress, maximumBytes)
        }
        _ = Darwin.lseek(descriptor, 0, SEEK_END)
        guard count > 0 else { return 0 }
        let data = Data(bytes.prefix(count))
        guard let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").last,
              let event = try? JSONDecoder().decode(
                  MacHelperDiagnosticEvent.self,
                  from: Data(line.utf8)
              ) else {
            return 0
        }
        return event.sequence
    }

    private static func safeTransactionID(_ value: String?) -> String? {
        guard let value,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value else {
            return nil
        }
        return value
    }

    private static func safeCode(_ value: String) -> String {
        guard !value.isEmpty,
              value.count <= 64,
              value.allSatisfy({
                  $0.isNumber || $0.isLetter || $0 == "." || $0 == "_"
                      || $0 == "-"
              }) else {
            return "unknown"
        }
        return value
    }

    private static func isOwnedPrivateDirectory(_ path: String) -> Bool {
        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              status.st_uid == Darwin.geteuid(),
              status.st_mode & mode_t(0o077) == 0 else {
            return false
        }
        return true
    }
}
