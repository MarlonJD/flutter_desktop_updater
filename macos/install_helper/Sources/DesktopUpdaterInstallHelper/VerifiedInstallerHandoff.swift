import Darwin
import Foundation
import Security

enum MacVerifiedInstallerKind: Equatable {
    case pkg
    case dmgInstallerApplication
}

private struct MacInstallerBundleRecord: Hashable {
    let identifier: String
    let path: String
    let shortVersion: String
    let bundleVersion: String
}

struct MacVerifiedInstallerExpectation: Equatable {
    let installerURL: URL
    let kind: MacVerifiedInstallerKind
    let targetURL: URL
    let packageIdentifier: String
    let expectedVersion: String
    let expectedBuildNumber: Int64
    let designatedRequirement: String
    let artifactSHA256: String
    let artifactLength: Int64
    let expectedPackageIdentifiers: [String]
    let expectedReceiptVersions: [String: String]
    let expectedExecutableSHA256: String
    let expectedBundleTreeSHA256: String
    let descriptorSHA256: String
    let provenanceSHA256: String

    init(
        installerURL: URL,
        kind: MacVerifiedInstallerKind,
        targetURL: URL = URL(fileURLWithPath: "/Applications"),
        packageIdentifier: String,
        expectedVersion: String,
        expectedBuildNumber: Int64 = 0,
        designatedRequirement: String,
        artifactSHA256: String,
        artifactLength: Int64,
        expectedPackageIdentifiers: [String]? = nil,
        expectedReceiptVersions: [String: String] = [:],
        expectedExecutableSHA256: String = "",
        expectedBundleTreeSHA256: String = "",
        descriptorSHA256: String = String(repeating: "0", count: 64),
        provenanceSHA256: String = String(repeating: "0", count: 64)
    ) {
        self.installerURL = installerURL
        self.kind = kind
        self.targetURL = targetURL
        self.packageIdentifier = packageIdentifier
        self.expectedVersion = expectedVersion
        self.expectedBuildNumber = expectedBuildNumber
        self.designatedRequirement = designatedRequirement
        self.artifactSHA256 = artifactSHA256
        self.artifactLength = artifactLength
        self.expectedPackageIdentifiers = expectedPackageIdentifiers
            ?? [packageIdentifier]
        self.expectedReceiptVersions = expectedReceiptVersions
        self.expectedExecutableSHA256 = expectedExecutableSHA256
        self.expectedBundleTreeSHA256 = expectedBundleTreeSHA256
        self.descriptorSHA256 = descriptorSHA256
        self.provenanceSHA256 = provenanceSHA256
    }

    func replacingInstallerURL(_ value: URL) -> Self {
        Self(
            installerURL: value,
            kind: kind,
            targetURL: targetURL,
            packageIdentifier: packageIdentifier,
            expectedVersion: expectedVersion,
            expectedBuildNumber: expectedBuildNumber,
            designatedRequirement: designatedRequirement,
            artifactSHA256: artifactSHA256,
            artifactLength: artifactLength,
            expectedPackageIdentifiers: expectedPackageIdentifiers,
            expectedReceiptVersions: expectedReceiptVersions,
            expectedExecutableSHA256: expectedExecutableSHA256,
            expectedBundleTreeSHA256: expectedBundleTreeSHA256,
            descriptorSHA256: descriptorSHA256,
            provenanceSHA256: provenanceSHA256
        )
    }

    func binding(_ evidence: MacVerifiedInstallerSecurityEvidence) -> Self {
        Self(
            installerURL: installerURL,
            kind: kind,
            targetURL: targetURL,
            packageIdentifier: packageIdentifier,
            expectedVersion: expectedVersion,
            expectedBuildNumber: expectedBuildNumber,
            designatedRequirement: designatedRequirement,
            artifactSHA256: artifactSHA256,
            artifactLength: artifactLength,
            expectedPackageIdentifiers: expectedPackageIdentifiers,
            expectedReceiptVersions: evidence.receiptVersions,
            expectedExecutableSHA256: evidence.executableSHA256,
            expectedBundleTreeSHA256: evidence.bundleTreeSHA256,
            descriptorSHA256: descriptorSHA256,
            provenanceSHA256: provenanceSHA256
        )
    }

    var hasSecurityBinding: Bool {
        Set(expectedReceiptVersions.keys)
            == Set(expectedPackageIdentifiers)
            && expectedReceiptVersions.values.allSatisfy { !$0.isEmpty }
            && validSHA256(expectedExecutableSHA256)
            && validSHA256(expectedBundleTreeSHA256)
    }
}

struct MacVerifiedInstallerSecurityEvidence: Equatable {
    let receiptVersions: [String: String]
    let executableSHA256: String
    let bundleTreeSHA256: String
}

struct MacProviderTransaction: Equatable {
    enum State: Equatable {
        case managerStarted
        case verificationPending
        case completed
        case manualActionRequired
    }

    let identity: String
    let state: State
}

protocol MacVerifiedInstallerChecking {
    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacVerifiedInstallerSecurityEvidence

    func verifyInstalledPackage(
        identifier: String,
        version _: String
    ) throws

    func verifyInstalledApplication(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws
}

extension MacVerifiedInstallerChecking {
    func verifyInstalledApplication(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws {
        try verifyInstalledPackage(
            identifier: expectation.packageIdentifier,
            version: expectation.expectedVersion
        )
    }
}

protocol MacVerifiedInstallerCheckingCreating: AnyObject {
    func makeVerifier(
        expectation: MacVerifiedInstallerExpectation
    ) throws -> any MacVerifiedInstallerChecking
}

protocol MacInstalledApplicationOwnershipValidating {
    func validate(_ applicationURL: URL) throws
}

struct SystemMacInstalledApplicationOwnershipValidator:
    MacInstalledApplicationOwnershipValidating
{
    func validate(_ applicationURL: URL) throws {
        let descriptor = applicationURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        defer { _ = Darwin.close(descriptor) }
        try validateDirectory(descriptor)
    }

    private func validateDirectory(_ descriptor: Int32) throws {
        var root = stat()
        guard Darwin.fstat(descriptor, &root) == 0,
              validOwnedNode(root, expectedKind: mode_t(S_IFDIR)) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        defer { _ = Darwin.closedir(stream) }
        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var value = stat()
            let status = name.withCString {
                Darwin.fstatat(
                    descriptor,
                    $0,
                    &value,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard status == 0, value.st_uid == 0 else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
            let kind = value.st_mode & mode_t(S_IFMT)
            switch kind {
            case mode_t(S_IFDIR):
                guard value.st_mode & 0o022 == 0 else {
                    throw MacVerifiedInstallerHandoffError.invalidExpectation
                }
                let child = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw MacVerifiedInstallerHandoffError.invalidExpectation
                }
                defer { _ = Darwin.close(child) }
                var opened = stat()
                guard Darwin.fstat(child, &opened) == 0,
                      opened.st_dev == value.st_dev,
                      opened.st_ino == value.st_ino else {
                    throw MacVerifiedInstallerHandoffError.invalidExpectation
                }
                try validateDirectory(child)
            case mode_t(S_IFREG):
                guard value.st_mode & 0o022 == 0 else {
                    throw MacVerifiedInstallerHandoffError.invalidExpectation
                }
            case mode_t(S_IFLNK):
                break
            default:
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
            errno = 0
        }
        guard errno == 0 else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
    }

    private func validOwnedNode(
        _ value: stat,
        expectedKind: mode_t
    ) -> Bool {
        value.st_uid == 0
            && value.st_mode & mode_t(S_IFMT) == expectedKind
            && value.st_mode & 0o022 == 0
    }
}

protocol MacFixedInstallerRunning {
    func spawnVerifiedInstaller(
        at url: URL,
        kind: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker
}

enum MacVerifiedInstallerHandoffError: Error, Equatable {
    case invalidExpectation
    case emptyProviderTransactionIdentity
    case installerFailed(Int32)
}

struct MacVerifiedInstallerHandoff {
    let verifier: any MacVerifiedInstallerChecking
    let runner: any MacFixedInstallerRunning

    func execute(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacProviderTransaction {
        let worker = try verifyAndSpawn(expectation)
        try worker.releaseAndWait()
        try verifyInstalled(expectation)
        return MacProviderTransaction(
            identity: worker.identity.providerTransactionIdentity,
            state: .completed
        )
    }

    func recover(
        _ expectation: MacVerifiedInstallerExpectation,
        transactionIdentity: String
    ) -> MacProviderTransaction {
        do {
            try verifier.verifyInstalledApplication(expectation)
            return .init(
                identity: transactionIdentity,
                state: .completed
            )
        } catch {
            return .init(
                identity: transactionIdentity,
                state: .manualActionRequired
            )
        }
    }

    func verifyAndSpawn(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> any MacGatedInstallerWorker {
        guard validated(expectation) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let evidence = try verifier.verifyInstaller(expectation)
        if expectation.hasSecurityBinding,
           evidence != MacVerifiedInstallerSecurityEvidence(
            receiptVersions: expectation.expectedReceiptVersions,
            executableSHA256: expectation.expectedExecutableSHA256,
            bundleTreeSHA256: expectation.expectedBundleTreeSHA256
           ) {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let worker = try runner.spawnVerifiedInstaller(
            at: expectation.installerURL,
            kind: expectation.kind
        )
        guard worker.identity.processIdentifier > 0,
              worker.identity.processStartIdentity.range(
                of: #"^macos:[0-9]+:[0-9]+$"#,
                options: .regularExpression
              ) != nil,
              !worker.identity.providerTransactionIdentity.isEmpty else {
            throw MacVerifiedInstallerHandoffError
                .emptyProviderTransactionIdentity
        }
        return worker
    }

    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacVerifiedInstallerSecurityEvidence {
        guard validated(expectation) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let evidence = try verifier.verifyInstaller(expectation)
        if expectation.hasSecurityBinding,
           evidence != MacVerifiedInstallerSecurityEvidence(
            receiptVersions: expectation.expectedReceiptVersions,
            executableSHA256: expectation.expectedExecutableSHA256,
            bundleTreeSHA256: expectation.expectedBundleTreeSHA256
           ) {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        return evidence
    }

    func verifyInstalled(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws {
        guard validated(expectation) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        try verifier.verifyInstalledApplication(expectation)
    }

    private func validated(
        _ expectation: MacVerifiedInstallerExpectation
    ) -> Bool {
        expectation.kind == .pkg
            && !expectation.packageIdentifier.isEmpty
            && !expectation.expectedVersion.isEmpty
            && expectation.expectedBuildNumber >= 0
            && !expectation.designatedRequirement.isEmpty
            && !expectation.expectedPackageIdentifiers.isEmpty
            && Set(expectation.expectedPackageIdentifiers).count
                == expectation.expectedPackageIdentifiers.count
            && expectation.expectedPackageIdentifiers.allSatisfy({
                $0.range(
                    of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9._-]{0,126}[a-zA-Z0-9])?$"#,
                    options: .regularExpression
                ) != nil
            })
            && validSHA256(expectation.artifactSHA256)
            && expectation.artifactLength > 0
            && validSHA256(expectation.descriptorSHA256)
            && validSHA256(expectation.provenanceSHA256)
    }
}

private func validSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy {
        $0.isNumber || ("a" ... "f").contains($0)
    }
}

protocol MacInstallerCommandRunning: AnyObject {
    func run(executable: String, arguments: [String]) throws -> Data
}

final class SystemMacInstallerCommandRunner: MacInstallerCommandRunning {
    private let maximumOutputLength: Int64 = 64 * 1024 * 1024

    func run(executable: String, arguments: [String]) throws -> Data {
        let outputRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "desktop-updater-command-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        let outputURL = outputRoot.appendingPathComponent("output")
        let descriptor = outputURL.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let output = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        output.closeFile()
        let directory = try MacTransactionDirectory(url: outputRoot)
        let data = try MacRetainedFileObject(
            directory: directory,
            name: outputURL.lastPathComponent
        ).readData(maximumLength: maximumOutputLength)
        guard process.terminationStatus == 0 else {
            throw MacVerifiedInstallerHandoffError.installerFailed(
                process.terminationStatus
            )
        }
        return data
    }
}

final class SystemMacVerifiedInstallerCheckerFactory:
    MacVerifiedInstallerCheckingCreating
{
    func makeVerifier(
        expectation _: MacVerifiedInstallerExpectation
    ) throws -> any MacVerifiedInstallerChecking {
        SystemMacVerifiedInstallerChecker(
            commandRunner: SystemMacInstallerCommandRunner()
        )
    }
}

final class SystemMacVerifiedInstallerChecker:
    MacVerifiedInstallerChecking
{
    private let commandRunner: any MacInstallerCommandRunning
    private let ownershipValidator:
        any MacInstalledApplicationOwnershipValidating

    init(
        commandRunner: any MacInstallerCommandRunning,
        ownershipValidator: any MacInstalledApplicationOwnershipValidating =
            SystemMacInstalledApplicationOwnershipValidator()
    ) {
        self.commandRunner = commandRunner
        self.ownershipValidator = ownershipValidator
    }

    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacVerifiedInstallerSecurityEvidence {
        let installer = expectation.installerURL.standardizedFileURL
        var status = stat()
        let installerDirectory = try MacTransactionDirectory(
            url: installer.deletingLastPathComponent()
        )
        let retainedInstaller = try MacRetainedFileObject(
            directory: installerDirectory,
            name: installer.lastPathComponent
        )
        guard expectation.kind == .pkg,
              installer.path == expectation.installerURL.path,
              installer.lastPathComponent == "installer.pkg",
              installer.path.withCString({ lstat($0, &status) }) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size == expectation.artifactLength,
              try retainedInstaller.sha256(
                  expectedLength: expectation.artifactLength
              ) == expectation.artifactSHA256 else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        _ = try commandRunner.run(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", installer.path]
        )
        _ = try commandRunner.run(
            executable: "/usr/sbin/spctl",
            arguments: [
                "--assess", "--type", "install", "--verbose=2",
                installer.path,
            ]
        )
        _ = try commandRunner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["stapler", "validate", installer.path]
        )
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "desktop_updater_pkg_expand_\(UUID().uuidString)",
                isDirectory: true
            )
        let expanded = parent.appendingPathComponent(
            "expanded",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        _ = try commandRunner.run(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--expand-full", installer.path, expanded.path]
        )
        let package = try singleComponentPackage(
            in: expanded,
            expectation: expectation
        )
        return MacVerifiedInstallerSecurityEvidence(
            receiptVersions: [package.identifier: package.version],
            executableSHA256: package.executableSHA256,
            bundleTreeSHA256: package.bundleTreeSHA256
        )
    }

    func verifyInstalledPackage(
        identifier: String,
        version: String
    ) throws {
        let data = try commandRunner.run(
            executable: "/usr/sbin/pkgutil",
            arguments: ["--pkg-info-plist", identifier]
        )
        guard let object = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
            object["pkgid"] as? String == identifier,
            let receiptVersion = object["pkg-version"] as? String,
            receiptVersion == version else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
    }

    func verifyInstalledApplication(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws {
        let target = expectation.targetURL.standardizedFileURL
        guard target.path == expectation.targetURL.path,
              try verifiedInstallerRealDirectory(target) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let targetDirectory = try MacTransactionDirectory(url: target)
        try ownershipValidator.validate(target)
        try targetDirectory.validatePathIdentity()
        let contentsDirectory = try MacTransactionDirectory(
            url: target.appendingPathComponent("Contents")
        )
        let infoFile = try MacRetainedFileObject(
            directory: contentsDirectory,
            name: "Info.plist"
        )
        guard let info = try PropertyListSerialization.propertyList(
                  from: infoFile.readData(maximumLength: 1_048_576),
                  options: [],
                  format: nil
              ) as? [String: Any],
              info["CFBundleIdentifier"] as? String
                == expectation.packageIdentifier,
              info["CFBundleShortVersionString"] as? String
                == expectation.expectedVersion,
              let build = info["CFBundleVersion"] as? String,
              Int64(build) == expectation.expectedBuildNumber,
              let executableName = info["CFBundleExecutable"] as? String,
              verifiedInstallerSimpleComponent(executableName),
              expectation.hasSecurityBinding else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let executableDirectory = try MacTransactionDirectory(
            url: target.appendingPathComponent("Contents/MacOS")
        )
        let executable = try MacRetainedFileObject(
            directory: executableDirectory,
            name: executableName
        )
        let helperDirectory = try MacTransactionDirectory(
            url: target.appendingPathComponent("Contents/Helpers")
        )
        let helper = try MacRetainedFileObject(
            directory: helperDirectory,
            name: "DesktopUpdaterInstallHelper"
        )
        guard verifiedInstallerExecutableIdentity(executable.identity),
              verifiedInstallerExecutableIdentity(helper.identity) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        try contentsDirectory.validatePathIdentity()
        try executableDirectory.validatePathIdentity()
        try helperDirectory.validatePathIdentity()
        try targetDirectory.validatePathIdentity()
        try macVerifyBundleSignature(
            bundleURL: target,
            requirement: expectation.designatedRequirement
        )
        let executableLength = try executable.length(
            maximumLength: 16 * 1024 * 1024 * 1024
        )
        guard try executable.sha256(expectedLength: executableLength)
                == expectation.expectedExecutableSHA256,
              try macAuthorizedTreeSHA256(target)
                == expectation.expectedBundleTreeSHA256 else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        for identifier in expectation.expectedPackageIdentifiers {
            try verifyInstalledPackage(
                identifier: identifier,
                version: expectation.expectedReceiptVersions[identifier]!
            )
        }
        try ownershipValidator.validate(target)
        try contentsDirectory.validatePathIdentity()
        try executableDirectory.validatePathIdentity()
        try helperDirectory.validatePathIdentity()
        try targetDirectory.validatePathIdentity()
    }

    private func singleComponentPackage(
        in root: URL,
        expectation: MacVerifiedInstallerExpectation
    ) throws -> (
        identifier: String,
        version: String,
        executableSHA256: String,
        bundleTreeSHA256: String
    ) {
        guard expectation.expectedPackageIdentifiers.count == 1,
              let expectedIdentifier =
                expectation.expectedPackageIdentifiers.first,
              try exactEntryNames(in: root) == [
                "Distribution", "component.pkg",
              ] else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let distribution = root.appendingPathComponent("Distribution")
        let distributionBundles = try validateDistribution(
            distribution,
            identifier: expectedIdentifier,
            version: expectation.expectedVersion
        )
        let component = root.appendingPathComponent(
            "component.pkg",
            isDirectory: true
        )
        guard try verifiedInstallerRealDirectory(component),
              try exactEntryNames(in: component) == [
                "Bom", "PackageInfo", "Payload",
              ],
              verifiedInstallerRegularFile(
                component.appendingPathComponent("Bom"),
                maximumLength: 64 * 1024 * 1024
              ) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let packageInfo = try validatePackageInfo(
            component.appendingPathComponent("PackageInfo"),
            expectation: expectation,
            identifier: expectedIdentifier,
            distributionBundles: distributionBundles
        )
        let payload = component.appendingPathComponent(
            "Payload",
            isDirectory: true
        )
        let targetName = expectation.targetURL.lastPathComponent
        guard verifiedInstallerSimpleComponent(targetName),
              try verifiedInstallerRealDirectory(payload),
              try exactEntryNames(in: payload) == [targetName] else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        try validateBOM(
            component.appendingPathComponent("Bom"),
            payload: payload
        )
        let application = try packagedApplication(
            at: payload.appendingPathComponent(targetName),
            expectation: expectation
        )
        try validatePackagedBundleRecords(
            distributionBundles,
            payload: payload,
            targetName: targetName,
            packageIdentifier: expectation.packageIdentifier
        )
        return (
            packageInfo.identifier,
            packageInfo.version,
            application.executableSHA256,
            application.bundleTreeSHA256
        )
    }

    private func validateBOM(_ bom: URL, payload: URL) throws {
        let data = try commandRunner.run(
            executable: "/usr/bin/lsbom",
            arguments: ["-p", "fmug", bom.path]
        )
        guard let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\n") else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        var bomModes: [String: UInt32] = [:]
        for line in text.dropLast().split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let fields = line.split(
                separator: "\t",
                omittingEmptySubsequences: false
            )
            guard fields.count == 4 else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
            let path = String(fields[0])
            let modeText = String(fields[1])
            let userIDText = String(fields[2])
            let groupIDText = String(fields[3])
            guard path == "." || (
                path.hasPrefix("./")
                    && verifiedInstallerPayloadRelativePath(
                        String(path.dropFirst(2))
                    ) != nil
            ),
                !path.contains("\t"),
                !path.contains("\r"),
                let mode = UInt32(modeText, radix: 8),
                let userID = UInt32(userIDText),
                let groupID = UInt32(groupIDText),
                userID == 0,
                groupID == 0,
                mode <= 0o177777,
                mode & 0o7000 == 0,
                [UInt32(S_IFDIR), UInt32(S_IFREG), UInt32(S_IFLNK)]
                    .contains(mode & UInt32(S_IFMT)),
                ![UInt32(S_IFDIR), UInt32(S_IFREG)].contains(
                    mode & UInt32(S_IFMT)
                ) || mode & 0o022 == 0,
                mode & UInt32(S_IFMT) != UInt32(S_IFDIR)
                    || mode & 0o005 == 0o005,
                mode & UInt32(S_IFMT) != UInt32(S_IFREG)
                    || (
                        mode & 0o004 == 0o004
                            && (mode & 0o111 == 0
                                || mode & 0o101 == 0o101)
                    ),
                bomModes.updateValue(mode, forKey: path) == nil,
                bomModes.count <= 100_001 else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
        }
        let expandedModes = try payloadModes(payload)
        let bomOnly = Set(bomModes.keys).subtracting(expandedModes.keys)
        let expandedOnly = Set(expandedModes.keys).subtracting(bomModes.keys)
        guard expandedOnly.isEmpty,
              bomOnly.allSatisfy({ path in
                  guard let mode = bomModes[path],
                        mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
                      return false
                  }
                  let separator = path.lastIndex(of: "/")
                  let name = separator.map {
                      String(path[path.index(after: $0)...])
                  } ?? path
                  guard name.hasPrefix("._"), name.count > 2 else {
                      return false
                  }
                  let sibling = separator.map {
                      String(path[...$0]) + String(name.dropFirst(2))
                  } ?? String(name.dropFirst(2))
                  return expandedModes[sibling] != nil
              }) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        for (path, bomMode) in bomModes where !bomOnly.contains(path) {
            guard let expandedMode = expandedModes[path],
                  expandedMode & 0o7000 == 0,
                  bomMode & UInt32(S_IFMT)
                    == expandedMode & UInt32(S_IFMT),
                  bomMode & 0o777 == expandedMode & 0o777 else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
        }
    }

    private func payloadModes(_ payload: URL) throws -> [String: UInt32] {
        let canonicalPayload = try verifiedInstallerCanonicalURL(payload)
        var result: [String: UInt32] = [:]
        func record(_ url: URL, path: String) throws {
            var value = stat()
            guard url.path.withCString({ Darwin.lstat($0, &value) }) == 0,
                  result.updateValue(
                      UInt32(value.st_mode) & 0o177777,
                      forKey: path
                  ) == nil,
                  result.count <= 100_001 else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
        }
        try record(canonicalPayload, path: ".")
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalPayload,
            includingPropertiesForKeys: nil
        ) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let prefix = canonicalPayload.path + "/"
        for case let url as URL in enumerator {
            guard url.path.hasPrefix(prefix) else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
            let relative = String(url.path.dropFirst(prefix.count))
            guard verifiedInstallerPayloadRelativePath(relative) != nil else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
            try record(url, path: "./\(relative)")
        }
        return result
    }

    private func validateDistribution(
        _ url: URL,
        identifier: String,
        version: String
    ) throws -> Set<MacInstallerBundleRecord> {
        guard verifiedInstallerRegularFile(url, maximumLength: 1_048_576)
        else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let document = try XMLDocument(
            data: try verifiedInstallerMetadataData(url),
            options: [.nodeLoadExternalEntitiesNever]
        )
        guard let root = document.rootElement(),
              root.name == "installer-gui-script",
              root.attribute(forName: "minSpecVersion")?.stringValue == "1",
              Set(root.attributes?.compactMap(\.name) ?? [])
                == ["minSpecVersion"] else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let elements = try document.nodes(forXPath: "//*")
            .compactMap { $0 as? XMLElement }
        let allowedElements: Set<String> = [
            "installer-gui-script", "pkg-ref", "bundle-version", "options",
            "choices-outline", "line", "choice", "bundle",
        ]
        guard elements.allSatisfy({
            guard let name = $0.name, allowedElements.contains(name) else {
                return false
            }
            let attributes = Set($0.attributes?.compactMap(\.name) ?? [])
            let allowedAttributes: Set<String>
            switch name {
            case "installer-gui-script":
                allowedAttributes = ["minSpecVersion"]
            case "pkg-ref":
                allowedAttributes = [
                    "id", "version", "onConclusion", "installKBytes",
                    "updateKBytes",
                ]
            case "options":
                allowedAttributes = [
                    "customize", "require-scripts", "hostArchitectures",
                    "rootVolumeOnly",
                ]
            case "line":
                allowedAttributes = ["choice"]
            case "choice":
                allowedAttributes = ["id", "visible"]
            case "bundle":
                allowedAttributes = [
                    "CFBundleShortVersionString", "CFBundleVersion", "id",
                    "path",
                ]
            default:
                allowedAttributes = []
            }
            return attributes.isSubset(of: allowedAttributes)
        }) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let options = try document.nodes(
            forXPath: "/installer-gui-script/options"
        ).compactMap { $0 as? XMLElement }
        let references = try document.nodes(forXPath: "//pkg-ref")
            .compactMap { $0 as? XMLElement }
        let terminal = references.filter {
            !($0.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let choices = try document.nodes(
            forXPath: "/installer-gui-script/choice"
        ).compactMap { $0 as? XMLElement }
        let outlineLines = try document.nodes(
            forXPath: "/installer-gui-script/choices-outline/line"
        ).compactMap { $0 as? XMLElement }
        let selectedLines = try document.nodes(
            forXPath:
                "/installer-gui-script/choices-outline/line/line"
        ).compactMap { $0 as? XMLElement }
        let bundleElements = try document.nodes(
            forXPath:
                "/installer-gui-script/pkg-ref/bundle-version/bundle"
        ).compactMap { $0 as? XMLElement }
        let allBundleElements = elements.filter { $0.name == "bundle" }
        let bundleRecords = try Set(bundleElements.map(bundleRecord))
        guard options.count == 1,
              options[0].attribute(forName: "customize")?.stringValue
                == "never",
              options[0].attribute(forName: "require-scripts")?.stringValue
                == "false",
              !references.isEmpty,
              references.allSatisfy({
                $0.attribute(forName: "id")?.stringValue == identifier
              }),
              terminal.count == 1,
              terminal[0].stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                == "#component.pkg",
              terminal[0].attribute(forName: "version")?.stringValue
                == version,
              terminal[0].attribute(forName: "onConclusion")?.stringValue
                == "none",
              choices.count == 2,
              choices.contains(where: {
                $0.attribute(forName: "id")?.stringValue == "default"
                    && ($0.elements(forName: "pkg-ref")).isEmpty
              }),
              choices.contains(where: {
                $0.attribute(forName: "id")?.stringValue == identifier
                    && $0.attribute(forName: "visible")?.stringValue
                        == "false"
                    && $0.elements(forName: "pkg-ref").count == 1
              }),
              outlineLines.count == 1,
              outlineLines[0].attribute(forName: "choice")?.stringValue
                == "default",
              selectedLines.count == 1,
              selectedLines[0].attribute(forName: "choice")?.stringValue
                == identifier,
              !bundleRecords.isEmpty,
              bundleElements.count == allBundleElements.count else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        return bundleRecords
    }

    private func validatePackageInfo(
        _ url: URL,
        expectation: MacVerifiedInstallerExpectation,
        identifier: String,
        distributionBundles: Set<MacInstallerBundleRecord>
    ) throws -> (identifier: String, version: String) {
        guard verifiedInstallerRegularFile(url, maximumLength: 1_048_576)
        else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let document = try XMLDocument(
            data: try verifiedInstallerMetadataData(url),
            options: [.nodeLoadExternalEntitiesNever]
        )
        guard let root = document.rootElement(),
              root.name == "pkg-info",
              root.attribute(forName: "identifier")?.stringValue
                == identifier,
              root.attribute(forName: "version")?.stringValue
                == expectation.expectedVersion,
              root.attribute(forName: "install-location")?.stringValue
                == expectation.targetURL.deletingLastPathComponent().path,
              root.attribute(forName: "auth")?.stringValue == "root",
              root.attribute(forName: "relocatable")?.stringValue == "false",
              root.attribute(forName: "postinstall-action")?.stringValue
                == "none" else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let allowedChildren: Set<String> = [
            "payload", "bundle-version", "upgrade-bundle", "update-bundle",
            "atomic-update-bundle", "strict-identifier", "relocate",
            "bundle",
        ]
        guard root.children?.compactMap({ $0 as? XMLElement }).allSatisfy({
            guard let name = $0.name else { return false }
            return allowedChildren.contains(name)
        }) ?? true else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let directBundleElements = try document.nodes(
            forXPath: "/pkg-info/bundle"
        ).compactMap { $0 as? XMLElement }
        let directBundles = try Set(directBundleElements.map(bundleRecord))
        let referenceBundles = try document.nodes(
            forXPath:
                "/pkg-info/bundle-version/bundle"
                    + " | /pkg-info/upgrade-bundle/bundle"
                    + " | /pkg-info/strict-identifier/bundle"
                    + " | /pkg-info/relocate/bundle"
        ).compactMap { $0 as? XMLElement }
        let allBundleElements = try document.nodes(forXPath: "//bundle")
            .compactMap { $0 as? XMLElement }
        guard !directBundles.isEmpty,
              directBundles == distributionBundles,
              allBundleElements.count
                == directBundleElements.count + referenceBundles.count,
              referenceBundles.allSatisfy({ element in
                  Set(element.attributes?.compactMap(\.name) ?? []) == ["id"]
                    && element.attribute(forName: "id")?.stringValue
                        == expectation.packageIdentifier
              }) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        return (identifier, expectation.expectedVersion)
    }

    private func bundleRecord(
        _ element: XMLElement
    ) throws -> MacInstallerBundleRecord {
        let attributes = Set(element.attributes?.compactMap(\.name) ?? [])
        guard attributes == [
            "CFBundleShortVersionString", "CFBundleVersion", "id", "path",
        ],
            let identifier = element.attribute(forName: "id")?.stringValue,
            verifiedInstallerIdentifier(identifier),
            let rawPath = element.attribute(forName: "path")?.stringValue,
            let path = verifiedInstallerPayloadRelativePath(rawPath),
            let shortVersion = element.attribute(
                forName: "CFBundleShortVersionString"
            )?.stringValue,
            !shortVersion.isEmpty,
            let bundleVersion = element.attribute(
                forName: "CFBundleVersion"
            )?.stringValue,
            !bundleVersion.isEmpty else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        return MacInstallerBundleRecord(
            identifier: identifier,
            path: path,
            shortVersion: shortVersion,
            bundleVersion: bundleVersion
        )
    }

    private func validatePackagedBundleRecords(
        _ records: Set<MacInstallerBundleRecord>,
        payload: URL,
        targetName: String,
        packageIdentifier: String
    ) throws {
        guard records.contains(where: {
            $0.path == targetName && $0.identifier == packageIdentifier
        }) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        for record in records {
            let bundleURL = payload.appendingPathComponent(record.path)
            let infoCandidate = bundleURL.appendingPathComponent(
                record.path.hasSuffix(".framework")
                    ? "Resources/Info.plist" : "Contents/Info.plist"
            )
            let canonicalBundle = try verifiedInstallerCanonicalURL(bundleURL)
            let infoURL = try verifiedInstallerCanonicalURL(infoCandidate)
            let bundlePrefix = canonicalBundle.path + "/"
            guard record.path == targetName
                    || record.path.hasPrefix(targetName + "/"),
                  try verifiedInstallerRealDirectory(bundleURL),
                  infoURL.path.hasPrefix(bundlePrefix),
                  let info = try PropertyListSerialization.propertyList(
                      from: verifiedInstallerMetadataData(infoURL),
                      options: [],
                      format: nil
                  ) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == record.identifier,
                  info["CFBundleShortVersionString"] as? String
                    == record.shortVersion,
                  info["CFBundleVersion"] as? String
                    == record.bundleVersion else {
                throw MacVerifiedInstallerHandoffError.invalidExpectation
            }
        }
    }

    private func packagedApplication(
        at application: URL,
        expectation: MacVerifiedInstallerExpectation
    ) throws -> (executableSHA256: String, bundleTreeSHA256: String) {
        guard try verifiedInstallerRealDirectory(application),
              let info = try PropertyListSerialization.propertyList(
                  from: verifiedInstallerMetadataData(
                      application.appendingPathComponent(
                          "Contents/Info.plist"
                      )
                  ),
                options: [],
                format: nil
              ) as? [String: Any],
              info["CFBundleIdentifier"] as? String
                == expectation.packageIdentifier,
              info["CFBundleShortVersionString"] as? String
                == expectation.expectedVersion,
              let build = info["CFBundleVersion"] as? String,
              Int64(build) == expectation.expectedBuildNumber,
              let executableName = info["CFBundleExecutable"] as? String,
              verifiedInstallerSimpleComponent(executableName),
              verifiedInstallerExecutableFile(
                  application.appendingPathComponent(
                      "Contents/MacOS/\(executableName)"
                  )
              ),
              verifiedInstallerExecutableFile(
                  application.appendingPathComponent(
                      "Contents/Helpers/DesktopUpdaterInstallHelper"
                  )
              ) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        try macVerifyBundleSignature(
            bundleURL: application,
            requirement: expectation.designatedRequirement
        )
        let executableSHA256 = try macBoundedFileSHA256(
            application.appendingPathComponent(
                "Contents/MacOS/\(executableName)"
            ),
            maximumLength: 16 * 1024 * 1024 * 1024
        )
        return (
            executableSHA256,
            try macAuthorizedTreeSHA256(application)
        )
    }

    private func exactEntryNames(in directory: URL) throws -> Set<String> {
        guard try verifiedInstallerRealDirectory(directory) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        let names = entries.map(\.lastPathComponent)
        guard names.count == Set(names).count else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        return Set(names)
    }
}

private func verifiedInstallerRealDirectory(_ url: URL) throws -> Bool {
    let values = try url.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    return values.isDirectory == true && values.isSymbolicLink != true
}

private func verifiedInstallerCanonicalURL(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard url.path.withCString({ Darwin.realpath($0, &buffer) }) != nil else {
        throw MacVerifiedInstallerHandoffError.invalidExpectation
    }
    return URL(fileURLWithPath: String(cString: buffer))
}

private func verifiedInstallerRegularFile(
    _ url: URL,
    maximumLength: Int64
) -> Bool {
    var value = stat()
    return url.path.withCString({ Darwin.lstat($0, &value) }) == 0
        && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        && value.st_size >= 0
        && value.st_size <= maximumLength
}

private func verifiedInstallerMetadataData(_ url: URL) throws -> Data {
    let directory = try MacTransactionDirectory(
        url: url.deletingLastPathComponent()
    )
    return try MacRetainedFileObject(
        directory: directory,
        name: url.lastPathComponent
    ).readData(maximumLength: 1_048_576)
}

private func verifiedInstallerSimpleComponent(_ value: String) -> Bool {
    !value.isEmpty && value != "." && value != ".."
        && !value.contains("/") && !value.contains("\0")
}

private func verifiedInstallerExecutableFile(_ url: URL) -> Bool {
    var value = stat()
    return url.path.withCString({ Darwin.lstat($0, &value) }) == 0
        && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        && value.st_mode & 0o101 == 0o101
        && value.st_mode & 0o004 == 0o004
        && value.st_mode & 0o022 == 0
        && value.st_mode & 0o7000 == 0
}

private func verifiedInstallerExecutableIdentity(
    _ identity: MacFileIdentity
) -> Bool {
    identity.mode & UInt16(S_IFMT) == UInt16(S_IFREG)
        && identity.mode & 0o101 == 0o101
        && identity.mode & 0o004 == 0o004
        && identity.mode & 0o022 == 0
        && identity.mode & 0o7000 == 0
}

private func verifiedInstallerIdentifier(_ value: String) -> Bool {
    value.range(
        of: #"^[a-zA-Z0-9](?:[a-zA-Z0-9._-]{0,126}[a-zA-Z0-9])?$"#,
        options: .regularExpression
    ) != nil
}

private func verifiedInstallerPayloadRelativePath(_ value: String) -> String? {
    let normalized = value.hasPrefix("./")
        ? String(value.dropFirst(2)) : value
    guard !normalized.isEmpty,
          !normalized.hasPrefix("/"),
          !normalized.hasSuffix("/"),
          !normalized.contains("\\"),
          normalized.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        return nil
    }
    return normalized
}
