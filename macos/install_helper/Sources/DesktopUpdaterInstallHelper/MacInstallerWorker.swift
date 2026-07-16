import Darwin
import Foundation

struct MacInstallerWorkerIdentity: Equatable {
    let processIdentifier: Int32
    let processStartIdentity: String
    let providerTransactionIdentity: String
}

protocol MacGatedInstallerWorker: AnyObject {
    var identity: MacInstallerWorkerIdentity { get }

    func releaseAndWait() throws
}

enum MacInstallerWorkerError: Error, Equatable {
    case invalidRequest
    case requiresRoot
    case spawnFailed
    case managerFailed(Int32)
}

struct MacInstallerWorkerRequest: Codable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let installerPath: String

    init(installerPath: String) {
        schemaVersion = Self.schemaVersion
        self.installerPath = installerPath
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try NativeStrictJSON.canonicalize(encoder.encode(self))
    }

    static func decodeStrict(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 16 * 1024,
              try NativeStrictJSON.canonicalize(data) == data,
              let object = try NativeStrictJSON.decode(data)
                as? [String: Any],
              Set(object.keys) == ["schemaVersion", "installerPath"],
              object["schemaVersion"] as? Int == schemaVersion else {
            throw MacInstallerWorkerError.invalidRequest
        }
        let request: Self
        do {
            request = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw MacInstallerWorkerError.invalidRequest
        }
        guard request.schemaVersion == schemaVersion,
              validInstallerPath(request.installerPath) else {
            throw MacInstallerWorkerError.invalidRequest
        }
        return request
    }

    private static func validInstallerPath(_ value: String) -> Bool {
        let url = URL(fileURLWithPath: value).standardizedFileURL
        let stage = url.deletingLastPathComponent()
        let policyDirectory = stage.deletingLastPathComponent()
        return url.path == value
            && url.lastPathComponent == "installer.pkg"
            && policyDirectory.deletingLastPathComponent().path
                == MacVerifiedInstallerProtectedStage.defaultBaseURL.path
            && stage.lastPathComponent.range(
                of: #"^desktop-updater-stage-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
                options: .regularExpression
            ) != nil
            && policyDirectory.lastPathComponent.range(
                of: #"^\.desktop-updater-stages-[0-9a-f]{64}$"#,
                options: .regularExpression
            ) != nil
    }
}

enum MacInstallerWorkerRuntime {
    static func run(
        requestData: Data,
        effectiveUserIdentifier: uid_t = Darwin.geteuid(),
        installerExecutor: (String) throws -> Void = execInstaller
    ) throws {
        // EOF before the parent releases the gate is a deliberate fail-closed
        // cancellation. No installer process has been created at this point.
        guard !requestData.isEmpty else { return }
        guard effectiveUserIdentifier == 0 else {
            throw MacInstallerWorkerError.requiresRoot
        }
        let request = try MacInstallerWorkerRequest.decodeStrict(requestData)
        try installerExecutor(request.installerPath)
    }

    private static func execInstaller(at installerPath: String) throws {
        let executable = "/usr/sbin/installer"
        let arguments = [
            executable, "-pkg", installerPath, "-target", "/",
        ]
        let environment = [
            "HOME=/var/root",
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR=/private/var/tmp",
        ]
        var argumentPointers = arguments.map { strdup($0) }
        var environmentPointers = environment.map { strdup($0) }
        guard argumentPointers.allSatisfy({ $0 != nil }),
              environmentPointers.allSatisfy({ $0 != nil }) else {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
            throw MacInstallerWorkerError.spawnFailed
        }
        argumentPointers.append(nil)
        environmentPointers.append(nil)
        defer {
            argumentPointers.forEach { free($0) }
            environmentPointers.forEach { free($0) }
        }
        let result = executable.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { arguments in
                environmentPointers.withUnsafeMutableBufferPointer {
                    environment in
                    Darwin.execve(
                        executablePointer,
                        arguments.baseAddress,
                        environment.baseAddress
                    )
                }
            }
        }
        guard result == 0 else {
            throw MacInstallerWorkerError.spawnFailed
        }
    }
}

final class MacPlatformInstallerRunner: MacFixedInstallerRunning {
    private let workerExecutableURL: URL

    init(
        workerExecutableURL: URL? = Bundle.main.executableURL
    ) {
        self.workerExecutableURL = workerExecutableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    func spawnVerifiedInstaller(
        at url: URL,
        kind: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker {
        guard kind == .pkg else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        return try SystemMacGatedInstallerWorker(
            executableURL: workerExecutableURL,
            installerURL: url
        )
    }
}

private final class SystemMacGatedInstallerWorker: MacGatedInstallerWorker {
    let identity: MacInstallerWorkerIdentity
    private let process: Process
    private var gateWriter: FileHandle?
    private let requestData: Data
    private let lock = NSLock()
    private var released = false

    init(executableURL: URL, installerURL: URL) throws {
        let canonicalExecutable = executableURL.standardizedFileURL
        guard canonicalExecutable.path == executableURL.path else {
            throw MacInstallerWorkerError.spawnFailed
        }
        requestData = try MacInstallerWorkerRequest(
            installerPath: installerURL.path
        ).encode()
        let gate = Pipe()
        let child = Process()
        child.executableURL = canonicalExecutable
        child.arguments = ["--verified-installer-worker"]
        child.environment = [
            "HOME": "/var/root",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/private/var/tmp",
        ]
        child.standardInput = gate
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
        } catch {
            gate.fileHandleForWriting.closeFile()
            throw MacInstallerWorkerError.spawnFailed
        }
        let pid = child.processIdentifier
        let startIdentity: String
        do {
            startIdentity = try macInstallerProcessStartIdentity(pid: pid)
        } catch {
            gate.fileHandleForWriting.closeFile()
            child.waitUntilExit()
            throw MacInstallerWorkerError.spawnFailed
        }
        process = child
        gateWriter = gate.fileHandleForWriting
        guard Darwin.fcntl(
            gate.fileHandleForWriting.fileDescriptor,
            F_SETNOSIGPIPE,
            1
        ) == 0 else {
            gate.fileHandleForWriting.closeFile()
            child.waitUntilExit()
            throw MacInstallerWorkerError.spawnFailed
        }
        identity = MacInstallerWorkerIdentity(
            processIdentifier: pid,
            processStartIdentity: startIdentity,
            providerTransactionIdentity: UUID().uuidString.lowercased()
        )
    }

    func releaseAndWait() throws {
        lock.lock()
        guard !released, let writer = gateWriter else {
            lock.unlock()
            throw MacInstallerWorkerError.invalidRequest
        }
        released = true
        gateWriter = nil
        lock.unlock()
        do {
            try writeAll(
                requestData,
                descriptor: writer.fileDescriptor
            )
            writer.closeFile()
        } catch {
            writer.closeFile()
            throw MacInstallerWorkerError.spawnFailed
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacInstallerWorkerError.managerFailed(
                process.terminationStatus
            )
        }
    }

    deinit {
        lock.lock()
        let writer = gateWriter
        gateWriter = nil
        lock.unlock()
        writer?.closeFile()
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw MacInstallerWorkerError.spawnFailed
                }
                offset += count
            }
        }
    }
}

func macInstallerProcessStartIdentity(pid: Int32) throws -> String {
    guard pid > 0 else { throw MacInstallerWorkerError.spawnFailed }
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    guard proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        &info,
        Int32(size)
    ) == size else {
        throw MacInstallerWorkerError.spawnFailed
    }
    return "macos:\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
}
