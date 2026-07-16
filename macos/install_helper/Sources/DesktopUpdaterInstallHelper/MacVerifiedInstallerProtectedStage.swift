import Darwin
import Foundation

enum MacVerifiedInstallerProtectedStageError: Error, Equatable {
    case invalidRoot
    case createFailed
    case copyFailed
}

struct MacVerifiedInstallerProtectedStage {
    static let defaultBaseURL = URL(
        fileURLWithPath: "/Library/PrivilegedHelperTools",
        isDirectory: true
    )

    let parentDirectory: MacTransactionDirectory
    let stageName: String

    var stageURL: URL {
        parentDirectory.url.appendingPathComponent(
            stageName,
            isDirectory: true
        )
    }

    var installerURL: URL {
        stageURL.appendingPathComponent("installer.pkg")
    }

    static func policyDirectoryName(policyID: String) -> String {
        ".desktop-updater-stages-"
            + macPrivilegeSHA256(Data(policyID.utf8))
    }

    static func transactionDirectoryName(transactionID: String) -> String {
        "desktop-updater-stage-\(transactionID)"
    }

    static func open(
        baseURL: URL = defaultBaseURL,
        policyID: String,
        createPolicyDirectory: Bool
    ) throws -> Self {
        guard validPolicyID(policyID) else {
            throw MacVerifiedInstallerProtectedStageError.invalidRoot
        }
        let base = try MacTransactionDirectory(url: baseURL)
        try validateBase(base)
        let policyName = policyDirectoryName(policyID: policyID)
        if createPolicyDirectory, !base.exists(name: policyName) {
            let created = policyName.withCString {
                Darwin.mkdirat(base.fileDescriptor, $0, mode_t(0o700))
            }
            guard created == 0 || errno == EEXIST else {
                throw MacVerifiedInstallerProtectedStageError.createFailed
            }
            try base.sync()
        }
        let parent = try MacTransactionDirectory(
            url: base.url.appendingPathComponent(
                policyName,
                isDirectory: true
            )
        )
        try validatePolicyDirectory(parent)
        return Self(parentDirectory: parent, stageName: "")
    }

    static func plan(
        baseURL: URL = defaultBaseURL,
        policyID: String,
        transactionID: String,
        createPolicyDirectory: Bool = true
    ) throws -> Self {
        let paths = try MacTransactionPaths(
            targetName: "ProtectedInstaller.app",
            transactionID: transactionID
        )
        let root = try open(
            baseURL: baseURL,
            policyID: policyID,
            createPolicyDirectory: createPolicyDirectory
        )
        return Self(
            parentDirectory: root.parentDirectory,
            stageName: transactionDirectoryName(
                transactionID: paths.transactionID
            )
        )
    }

    func copyInstaller(
        from source: MacRetainedFileObject,
        expectedLength: Int64
    ) throws
        -> (stageIdentity: MacFileIdentity, installerIdentity: MacFileIdentity)
    {
        try Self.validatePolicyDirectory(parentDirectory)
        let created = stageName.withCString {
            Darwin.mkdirat(parentDirectory.fileDescriptor, $0, mode_t(0o700))
        }
        guard created == 0 else {
            throw MacVerifiedInstallerProtectedStageError.createFailed
        }
        var shouldRemove = true
        do {
            let stage = try MacTransactionDirectory(url: stageURL)
            try Self.validateOwnedStageDirectory(stage)
            let descriptor = "installer.pkg".withCString {
                Darwin.openat(
                    stage.fileDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o400)
                )
            }
            guard descriptor >= 0 else {
                throw MacVerifiedInstallerProtectedStageError.createFailed
            }
            var isOpen = true
            do {
                try source.copyContents(
                    to: descriptor,
                    expectedLength: expectedLength
                )
                guard Darwin.fsync(descriptor) == 0,
                      Darwin.close(descriptor) == 0 else {
                    throw MacVerifiedInstallerProtectedStageError.copyFailed
                }
                isOpen = false
                try stage.sync()
                try parentDirectory.sync()
                let installerIdentity = try stage.identity(
                    name: "installer.pkg",
                    rejectSymbolicLink: true
                )
                guard installerIdentity.userIdentifier == Darwin.geteuid(),
                      installerIdentity.mode & UInt16(S_IFMT)
                        == UInt16(S_IFREG),
                      installerIdentity.mode & 0o222 == 0 else {
                    throw MacVerifiedInstallerProtectedStageError.copyFailed
                }
                shouldRemove = false
                return (stage.identity, installerIdentity)
            } catch {
                if isOpen { _ = Darwin.close(descriptor) }
                throw error
            }
        } catch {
            if shouldRemove { try? removeIfPresent() }
            throw error
        }
    }

    func removeIfPresent(
        expectedIdentity: MacFileIdentity? = nil
    ) throws {
        try Self.validatePolicyDirectory(parentDirectory)
        guard parentDirectory.exists(name: stageName) else { return }
        let actual = try parentDirectory.identity(
            name: stageName,
            rejectSymbolicLink: true
        )
        if let expectedIdentity, actual != expectedIdentity {
            throw MacVerifiedInstallerProtectedStageError.invalidRoot
        }
        guard actual.userIdentifier == Darwin.geteuid(),
              actual.mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
              actual.mode & 0o077 == 0 else {
            throw MacVerifiedInstallerProtectedStageError.invalidRoot
        }
        try parentDirectory.removeTree(
            name: stageName,
            expectedIdentity: actual
        )
    }

    private static func validateBase(
        _ directory: MacTransactionDirectory
    ) throws {
        let identity = directory.identity
        guard identity.userIdentifier == Darwin.geteuid(),
              identity.mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
              identity.mode & 0o022 == 0 else {
            throw MacVerifiedInstallerProtectedStageError.invalidRoot
        }
    }

    private static func validatePolicyDirectory(
        _ directory: MacTransactionDirectory
    ) throws {
        let identity = directory.identity
        guard identity.userIdentifier == Darwin.geteuid(),
              identity.mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
              identity.mode & 0o077 == 0 else {
            throw MacVerifiedInstallerProtectedStageError.invalidRoot
        }
        try directory.validatePathIdentity()
    }

    private static func validateOwnedStageDirectory(
        _ directory: MacTransactionDirectory
    ) throws {
        try validatePolicyDirectory(directory)
    }

    private static func validPolicyID(_ value: String) -> Bool {
        value.range(
            of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9._-]{0,254}[a-zA-Z0-9])?$"#,
            options: .regularExpression
        ) != nil
    }
}
