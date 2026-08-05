import Darwin
import Foundation

public enum MacApplicationRestartError: Error, Equatable {
    case executableUnavailable
    case executableIdentityMismatch
    case lifetimeBarrierUnavailable
    case readinessProofUnavailable
    case descriptorIsolationUnavailable
    case processCreationFailed
    case readinessTimedOut
    case readinessProofInvalid
}

public final class MacApplicationRestartReservation {
    private let lock = NSLock()
    private var commitHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?

    init(
        commit: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        commitHandler = commit
        cancelHandler = cancel
    }

    public func commit() {
        lock.lock()
        let handler = commitHandler
        commitHandler = nil
        cancelHandler = nil
        lock.unlock()
        handler?()
    }

    public func cancel() {
        lock.lock()
        let handler = cancelHandler
        commitHandler = nil
        cancelHandler = nil
        lock.unlock()
        handler?()
    }

    deinit {
        cancel()
    }
}

extension MacApplicationRestartError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            return "The running macOS executable is unavailable."
        case .executableIdentityMismatch:
            return "The macOS restart executable identity changed."
        case .lifetimeBarrierUnavailable:
            return "The macOS restart lifetime barrier is unavailable."
        case .readinessProofUnavailable:
            return "The macOS restart readiness proof is unavailable."
        case .descriptorIsolationUnavailable:
            return "The macOS restart descriptor isolation is unavailable."
        case .processCreationFailed:
            return "The macOS restart process could not be created."
        case .readinessTimedOut:
            return "The macOS restart process did not become ready."
        case .readinessProofInvalid:
            return "The macOS restart readiness proof was invalid."
        }
    }
}

public struct MacApplicationRestarter {
    private static let lifetimeDescriptorEnvironment =
        "DESKTOP_UPDATER_RESTART_LIFETIME_FD"
    private static let readinessDescriptorEnvironment =
        "DESKTOP_UPDATER_RESTART_READY_FD"
    private static let restartedEnvironment = "DESKTOP_UPDATER_RESTARTED"
    private static let reexecEnvironment = "DESKTOP_UPDATER_RESTART_REEXEC"

    private let currentExecutableURL: () -> URL?
    private let schedule: (URL) throws -> Void

    public init() {
        currentExecutableURL = { Bundle.main.executableURL }
        schedule = { executableURL in
            let reservation = try DarwinMacApplicationRestartScheduler.schedule(
                executableURL: executableURL,
                reexecAfterReplacement: false
            )
            reservation.commit()
        }
    }

    init(
        currentExecutableURL: @escaping () -> URL?,
        schedule: @escaping (URL) throws -> Void
    ) {
        self.currentExecutableURL = currentExecutableURL
        self.schedule = schedule
    }

    public func scheduleCurrentApplicationRestart() throws {
        guard let executableURL = currentExecutableURL(),
              executableURL.isFileURL,
              !executableURL.path.isEmpty else {
            throw MacApplicationRestartError.executableUnavailable
        }
        try schedule(executableURL)
    }

    public func prepareCurrentApplicationRestart()
        throws -> MacApplicationRestartReservation {
        guard let executableURL = currentExecutableURL(),
              executableURL.isFileURL,
              !executableURL.path.isEmpty else {
            throw MacApplicationRestartError.executableUnavailable
        }
        return try DarwinMacApplicationRestartScheduler.schedule(
            executableURL: executableURL,
            reexecAfterReplacement: true
        )
    }

    public static func awaitRestartParentExitIfRequested() -> Bool {
        let lifetimeValue = getenv(lifetimeDescriptorEnvironment)
            .map { String(cString: $0) }
        let readinessValue = getenv(readinessDescriptorEnvironment)
            .map { String(cString: $0) }
        guard lifetimeValue != nil || readinessValue != nil else {
            return true
        }
        unsetenv(lifetimeDescriptorEnvironment)
        unsetenv(readinessDescriptorEnvironment)

        guard let lifetimeValue,
              let readinessValue,
              let lifetimeDescriptor = strictDescriptor(lifetimeValue),
              let readinessDescriptor = strictDescriptor(readinessValue),
              lifetimeDescriptor != readinessDescriptor,
              isPipe(lifetimeDescriptor, accessMode: O_RDONLY),
              isPipe(readinessDescriptor, accessMode: O_WRONLY) else {
            return false
        }

        var readiness: UInt8 = 1
        let sent = withUnsafePointer(to: &readiness) {
            retryingWrite(readinessDescriptor, $0, 1)
        }
        close(readinessDescriptor)
        guard sent == 1 else {
            close(lifetimeDescriptor)
            return false
        }

        var ignored: UInt8 = 0
        let lifetimeResult = withUnsafeMutablePointer(to: &ignored) {
            retryingRead(lifetimeDescriptor, $0, 1)
        }
        close(lifetimeDescriptor)
        guard lifetimeResult == 0 else {
            unsetenv(restartedEnvironment)
            return false
        }
        setenv(restartedEnvironment, "1", 1)
        guard reexecCurrentExecutableIfRequested() else {
            unsetenv(restartedEnvironment)
            return false
        }
        return true
    }

    private static func reexecCurrentExecutableIfRequested() -> Bool {
        guard let value = getenv(reexecEnvironment),
              String(cString: value) == "1" else {
            return true
        }
        guard let executableURL = Bundle.main.executableURL,
              executableURL.isFileURL,
              !executableURL.path.isEmpty else {
            unsetenv(reexecEnvironment)
            return false
        }
        guard waitForReplacement(
            executablePath: executableURL.path
        ) else {
            unsetenv(reexecEnvironment)
            return false
        }

        var arguments = CommandLine.arguments
        if arguments.isEmpty {
            arguments = [executableURL.path]
        }
        var pointers = arguments.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        unsetenv(reexecEnvironment)
        let result = pointers.withUnsafeMutableBufferPointer { buffer in
            executableURL.path.withCString { executable in
                execve(executable, buffer.baseAddress, environ)
            }
        }
        return result == 0
    }

    private static func waitForReplacement(executablePath: String) -> Bool {
        guard let currentIdentity = try? MacExecutableVnodeIdentity.current()
        else {
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let pathIdentity = try? MacExecutableVnodeIdentity.pathIdentity(
                executablePath
            ), pathIdentity != currentIdentity {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private static func strictDescriptor(_ value: String) -> Int32? {
        guard !value.isEmpty,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let descriptor = Int32(value),
              descriptor > STDERR_FILENO else {
            return nil
        }
        return descriptor
    }

    private static func isPipe(_ descriptor: Int32, accessMode: Int32) -> Bool {
        var status = stat()
        let flags = fcntl(descriptor, F_GETFL)
        return flags >= 0
            && flags & O_ACCMODE == accessMode
            && fstat(descriptor, &status) == 0
            && (status.st_mode & S_IFMT) == S_IFIFO
    }
}

private enum DarwinMacApplicationRestartScheduler {
    private static let readinessTimeoutMilliseconds: Int32 = 10_000

    static func schedule(
        executableURL: URL,
        reexecAfterReplacement: Bool
    ) throws -> MacApplicationRestartReservation {
        let expectedExecutableIdentity = try MacExecutableVnodeIdentity.current()
        let executablePath = executableURL.path
        guard executableURL.isFileURL,
              executablePath.first == "/",
              access(executablePath, X_OK) == 0 else {
            throw MacApplicationRestartError.executableUnavailable
        }

        var lifetimePipe = [Int32](repeating: -1, count: 2)
        guard pipe(&lifetimePipe) == 0 else {
            throw MacApplicationRestartError.lifetimeBarrierUnavailable
        }
        guard markCloseOnExec(lifetimePipe),
              moveAboveStandardDescriptors(&lifetimePipe) else {
            closePair(lifetimePipe)
            throw MacApplicationRestartError.lifetimeBarrierUnavailable
        }
        var readinessPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&readinessPipe) == 0 else {
            closePair(lifetimePipe)
            throw MacApplicationRestartError.readinessProofUnavailable
        }
        guard markCloseOnExec(readinessPipe),
              moveAboveStandardDescriptors(&readinessPipe) else {
            closePair(readinessPipe)
            closePair(lifetimePipe)
            throw MacApplicationRestartError.readinessProofUnavailable
        }
        let environment = childEnvironment(
            lifetimeDescriptor: lifetimePipe[0],
            readinessDescriptor: readinessPipe[1],
            reexecAfterReplacement: reexecAfterReplacement
        )
        var child: pid_t = 0
        let spawnResult: Int32
        do {
            spawnResult = try spawnIsolated(
                child: &child,
                executablePath: executablePath,
                arguments: [executablePath],
                environment: environment,
                inheritedDescriptors: [
                    lifetimePipe[0],
                    readinessPipe[1]
                ]
            )
        } catch {
            closePair(readinessPipe)
            closePair(lifetimePipe)
            throw error
        }

        guard spawnResult == 0, child > 0 else {
            closePair(readinessPipe)
            closePair(lifetimePipe)
            throw MacApplicationRestartError.processCreationFailed
        }

        let childExecutableIdentity = waitForExecutableIdentity(
            child: child
        )
        guard childExecutableIdentity == expectedExecutableIdentity else {
            terminateAndWait(child)
            closePair(readinessPipe)
            closePair(lifetimePipe)
            throw MacApplicationRestartError.executableIdentityMismatch
        }

        close(lifetimePipe[0])
        lifetimePipe[0] = -1
        close(readinessPipe[1])
        readinessPipe[1] = -1

        var descriptor = pollfd(
            fd: readinessPipe[0],
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        var observed: Int32
        repeat {
            observed = poll(&descriptor, 1, readinessTimeoutMilliseconds)
        } while observed < 0 && errno == EINTR

        guard observed > 0 else {
            terminateAndWait(child)
            closePair(readinessPipe)
            closePair(lifetimePipe)
            throw observed == 0
                ? MacApplicationRestartError.readinessTimedOut
                : MacApplicationRestartError.readinessProofInvalid
        }

        var readiness: UInt8 = 0
        let received = withUnsafeMutablePointer(to: &readiness) {
            retryingRead(readinessPipe[0], $0, 1)
        }
        close(readinessPipe[0])
        readinessPipe[0] = -1
        guard received == 1, readiness == 1 else {
            terminateAndWait(child)
            closePair(lifetimePipe)
            throw MacApplicationRestartError.readinessProofInvalid
        }

        let pending = DarwinMacApplicationRestartProcess(
            child: child,
            lifetimeDescriptor: lifetimePipe[1]
        )
        lifetimePipe[1] = -1
        return MacApplicationRestartReservation(
            commit: pending.commit,
            cancel: pending.cancel
        )
    }

    private static func waitForExecutableIdentity(
        child: pid_t
    ) -> MacExecutableVnodeIdentity? {
        let deadline = Date().addingTimeInterval(
            TimeInterval(readinessTimeoutMilliseconds) / 1_000
        )
        var observed: MacExecutableVnodeIdentity?
        repeat {
            observed = try? MacExecutableVnodeIdentity.process(child)
            if observed != nil {
                return observed
            }
            if kill(child, 0) != 0 && errno == ESRCH {
                return nil
            }
            usleep(10_000)
        } while Date() < deadline
        return observed
    }

    private static func childEnvironment(
        lifetimeDescriptor: Int32,
        readinessDescriptor: Int32,
        reexecAfterReplacement: Bool
    ) -> [String] {
        let lifetimePrefix =
            "DESKTOP_UPDATER_RESTART_LIFETIME_FD="
        let readinessPrefix =
            "DESKTOP_UPDATER_RESTART_READY_FD="
        let restartedPrefix = "DESKTOP_UPDATER_RESTARTED="
        let reexecPrefix = "DESKTOP_UPDATER_RESTART_REEXEC="
        var result: [String] = []
        var cursor = environ
        while let entry = cursor.pointee {
            let value = String(cString: entry)
            if !value.hasPrefix(lifetimePrefix),
               !value.hasPrefix(readinessPrefix),
               !value.hasPrefix(restartedPrefix),
               !value.hasPrefix(reexecPrefix) {
                result.append(value)
            }
            cursor = cursor.advanced(by: 1)
        }
        result.append("\(lifetimePrefix)\(lifetimeDescriptor)")
        result.append("\(readinessPrefix)\(readinessDescriptor)")
        // The marker must be present in the exec environment. Setting it
        // after plugin registration is too late for Dart's immutable
        // Platform.environment snapshot.
        result.append("\(restartedPrefix)1")
        if reexecAfterReplacement {
            result.append("\(reexecPrefix)1")
        }
        return result
    }

    private static func withOwnedCStringArray<Result>(
        _ values: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Result
    ) -> Result {
        var pointers = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }
        return pointers.withUnsafeMutableBufferPointer {
            body($0.baseAddress)
        }
    }

    private static func spawnIsolated(
        child: inout pid_t,
        executablePath: String,
        arguments: [String],
        environment: [String],
        inheritedDescriptors: [Int32]
    ) throws -> Int32 {
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw MacApplicationRestartError.descriptorIsolationUnavailable
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0 else {
            throw MacApplicationRestartError.descriptorIsolationUnavailable
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw MacApplicationRestartError.descriptorIsolationUnavailable
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for descriptor in inheritedDescriptors {
            guard posix_spawn_file_actions_addinherit_np(
                &fileActions,
                descriptor
            ) == 0 else {
                throw MacApplicationRestartError
                    .descriptorIsolationUnavailable
            }
        }

        return withOwnedCStringArray(arguments) { argumentPointers in
            withOwnedCStringArray(environment) { environmentPointers in
                executablePath.withCString { executable in
                    posix_spawn(
                        &child,
                        executable,
                        &fileActions,
                        &attributes,
                        argumentPointers,
                        environmentPointers
                    )
                }
            }
        }
    }

    private static func closePair(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 {
            close(descriptor)
        }
    }

    private static func moveAboveStandardDescriptors(
        _ descriptors: inout [Int32]
    ) -> Bool {
        for index in descriptors.indices
            where descriptors[index] <= STDERR_FILENO {
            let replacement = fcntl(
                descriptors[index],
                F_DUPFD_CLOEXEC,
                STDERR_FILENO + 1
            )
            guard replacement >= 0 else { return false }
            close(descriptors[index])
            descriptors[index] = replacement
        }
        return markCloseOnExec(descriptors)
    }

    private static func markCloseOnExec(_ descriptors: [Int32]) -> Bool {
        for descriptor in descriptors {
            guard descriptor >= 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0 else {
                return false
            }
        }
        return true
    }

    private static func terminateAndWait(_ process: pid_t) {
        _ = kill(process, SIGKILL)
        var status: Int32 = 0
        while waitpid(process, &status, 0) < 0 && errno == EINTR {}
    }
}

private final class DarwinMacApplicationRestartProcess {
    private let lock = NSLock()
    private let child: pid_t
    private var lifetimeDescriptor: Int32

    init(child: pid_t, lifetimeDescriptor: Int32) {
        self.child = child
        self.lifetimeDescriptor = lifetimeDescriptor
    }

    func commit() {
        lock.lock()
        guard lifetimeDescriptor >= 0 else {
            lock.unlock()
            return
        }
        let descriptor = lifetimeDescriptor
        lifetimeDescriptor = -1
        lock.unlock()
        MacRestartLifetimeBarriers.retain(descriptor)
    }

    func cancel() {
        lock.lock()
        guard lifetimeDescriptor >= 0 else {
            lock.unlock()
            return
        }
        let descriptor = lifetimeDescriptor
        lifetimeDescriptor = -1
        lock.unlock()
        _ = kill(child, SIGKILL)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        close(descriptor)
    }
}

private struct MacExecutableVnodeIdentity: Equatable {
    let device: UInt32
    let inode: UInt64
    let generation: UInt32

    static func current() throws -> Self {
        guard let header = _dyld_get_image_header(0) else {
            throw MacApplicationRestartError.executableIdentityMismatch
        }
        return try regionIdentity(
            processIdentifier: getpid(),
            address: UInt64(UInt(bitPattern: header))
        )
    }

    static func process(_ processIdentifier: pid_t) throws -> Self {
        var path = [CChar](
            repeating: 0,
            count: 4096
        )
        let length = path.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(
                processIdentifier,
                buffer.baseAddress,
                UInt32(buffer.count)
            )
        }
        guard length > 0, length < path.count else {
            throw MacApplicationRestartError.executableIdentityMismatch
        }
        return try pathIdentity(String(cString: path))
    }

    fileprivate static func pathIdentity(_ path: String) throws -> Self {
        var status = stat()
        let result = path.withCString { value in
            Darwin.lstat(value, &status)
        }
        guard result == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw MacApplicationRestartError.executableIdentityMismatch
        }
        return Self(
            device: UInt32(status.st_dev),
            inode: status.st_ino,
            generation: UInt32(status.st_gen)
        )
    }

    private static func regionIdentity(
        processIdentifier: pid_t,
        address: UInt64
    ) throws -> Self {
        var information = proc_regionwithpathinfo()
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDREGIONPATHINFO,
            address,
            &information,
            Int32(MemoryLayout.size(ofValue: information))
        )
        guard result == MemoryLayout.size(ofValue: information),
              information.prp_prinfo.pri_address <= address,
              address < information.prp_prinfo.pri_address
                + information.prp_prinfo.pri_size,
              information.prp_prinfo.pri_protection
                & UInt32(VM_PROT_EXECUTE) != 0,
              information.prp_vip.vip_vi.vi_type
                == Int32(VREG.rawValue) else {
            throw MacApplicationRestartError.executableIdentityMismatch
        }
        return identity(information)
    }

    private static func identity(
        _ information: proc_regionwithpathinfo
    ) -> Self {
        let status = information.prp_vip.vip_vi.vi_stat
        return Self(
            device: status.vst_dev,
            inode: status.vst_ino,
            generation: status.vst_gen
        )
    }
}

private func retryingRead(
    _ descriptor: Int32,
    _ buffer: UnsafeMutableRawPointer,
    _ count: Int
) -> Int {
    var result: Int
    repeat {
        result = Darwin.read(descriptor, buffer, count)
    } while result < 0 && errno == EINTR
    return result
}

private func retryingWrite(
    _ descriptor: Int32,
    _ buffer: UnsafeRawPointer,
    _ count: Int
) -> Int {
    var result: Int
    repeat {
        result = Darwin.write(descriptor, buffer, count)
    } while result < 0 && errno == EINTR
    return result
}

private enum MacRestartLifetimeBarriers {
    private static let lock = NSLock()
    private static var descriptors: [Int32] = []

    static func retain(_ descriptor: Int32) {
        lock.lock()
        descriptors.append(descriptor)
        lock.unlock()
    }
}
