import Foundation

public struct RuntimeStagedArtifact {
    public let stagedPath: URL
    public let stageRoot: URL
    public let provenance: StageProvenanceState
}

public struct RuntimeArchiveLimits {
    public let maximumArchiveEntries: Int64
    public let maximumUncompressedBytes: Int64
    public let maximumSingleEntryBytes: Int64

    public init(
        maximumArchiveEntries: Int64 = 100_000,
        maximumUncompressedBytes: Int64 = 8 * 1024 * 1024 * 1024,
        maximumSingleEntryBytes: Int64 = 4 * 1024 * 1024 * 1024
    ) {
        self.maximumArchiveEntries = maximumArchiveEntries
        self.maximumUncompressedBytes = maximumUncompressedBytes
        self.maximumSingleEntryBytes = maximumSingleEntryBytes
    }

    public init(configuration: RuntimeConfiguration) {
        maximumArchiveEntries = configuration.maximumArchiveEntries
        maximumUncompressedBytes = configuration.maximumUncompressedBytes
        maximumSingleEntryBytes = configuration.maximumSingleEntryBytes
    }
}

public struct MacArtifactStager {
    private let applicationTrustValidator: ((URL, String) throws -> Void)?

    public init() {
        applicationTrustValidator = nil
    }

    init(
        applicationTrustValidator: @escaping (URL, String) throws -> Void
    ) {
        self.applicationTrustValidator = applicationTrustValidator
    }

    public func stageZip(
        archive: URL,
        stagingRoot: URL,
        descriptor: ReleaseDescriptor,
        expectedPackageId: String,
        expectedTeamIdentifier: String,
        limits: RuntimeArchiveLimits = RuntimeArchiveLimits()
    ) throws -> RuntimeStagedArtifact {
        try validateDescriptorIdentity(
            descriptor,
            expectedPackageId: expectedPackageId,
            artifactKind: "zip"
        )
        try preflightZip(archive, limits: limits)
        let ownedStage = try ownedStage(in: stagingRoot)
        do {
            try run("/usr/bin/ditto", [
                "-x", "-k", "--sequesterRsrc", "--rsrc",
                archive.path, ownedStage.path,
            ])
            let app = try exactTopLevelApp(
                in: ownedStage,
                named: descriptor.appName
            )
            try validateApp(
                app,
                expectedPackageId: expectedPackageId,
                expectedTeamIdentifier: expectedTeamIdentifier
            )
            try FileManager.default.copyItem(
                at: archive,
                to: ownedStage.appendingPathComponent(
                    ".desktop_updater_artifact.zip"
                )
            )
            try writeManifest(descriptor, to: ownedStage)
            return try finalize(
                stagedPath: app,
                stageRoot: ownedStage,
                descriptor: descriptor
            )
        } catch {
            try? FileManager.default.removeItem(at: ownedStage)
            throw error
        }
    }

    public func stageDMG(
        dmg: URL,
        stagingRoot: URL,
        descriptor: ReleaseDescriptor,
        expectedPackageId: String,
        expectedTeamIdentifier: String
    ) throws -> RuntimeStagedArtifact {
        try validateDescriptorIdentity(
            descriptor,
            expectedPackageId: expectedPackageId,
            artifactKind: "dmg"
        )
        let metadata = try dictionary(descriptor.install.rawJSON["macosDmg"])
        if (metadata["verifyPrimarySignature"] as? Bool) != false {
            try run("/usr/bin/codesign", ["--verify", "--verbose=4", dmg.path])
        }
        let plist = try run(
            "/usr/bin/hdiutil",
            ["attach", "-readonly", "-nobrowse", "-plist", dmg.path],
            capturesOutput: true
        )
        let mount = try mountPoint(from: plist)
        let ownedStage = try ownedStage(in: stagingRoot)
        do {
            let appName = try string(metadata, "appBundleName")
            let source = try exactTopLevelApp(in: mount, named: appName)
            let destination = ownedStage.appendingPathComponent(appName)
            try run("/usr/bin/ditto", [source.path, destination.path])
            try validateApp(
                destination,
                expectedPackageId: expectedPackageId,
                expectedTeamIdentifier: expectedTeamIdentifier
            )
            try FileManager.default.copyItem(
                at: dmg,
                to: ownedStage.appendingPathComponent("artifact.dmg")
            )
            try writeManifest(descriptor, to: ownedStage)
            try run("/usr/bin/hdiutil", ["detach", mount.path])
            return try finalize(
                stagedPath: destination,
                stageRoot: ownedStage,
                descriptor: descriptor
            )
        } catch {
            _ = try? run("/usr/bin/hdiutil", ["detach", mount.path])
            try? FileManager.default.removeItem(at: ownedStage)
            throw error
        }
    }

    public func stagePKG(
        pkg: URL,
        stagingRoot: URL,
        descriptor: ReleaseDescriptor,
        expectedPackageId: String
    ) throws -> RuntimeStagedArtifact {
        try validateDescriptorIdentity(
            descriptor,
            expectedPackageId: expectedPackageId,
            artifactKind: "pkgInstaller"
        )
        let metadata = try dictionary(
            descriptor.install.normalizedJSON["macosPkg"]
        )
        let expectedPackageIds = try strings(metadata, "expectedPackageIds")
        _ = try run(
            "/usr/sbin/pkgutil",
            ["--check-signature", pkg.path],
            capturesOutput: true
        )
        try run("/usr/sbin/spctl", ["--assess", "--type", "install", pkg.path])
        try run("/usr/bin/xcrun", ["stapler", "validate", pkg.path])
        let ownedStage = try ownedStage(in: stagingRoot)
        do {
            let expanded = ownedStage.appendingPathComponent("expanded-pkg")
            try run(
                "/usr/sbin/pkgutil",
                ["--expand-full", pkg.path, expanded.path]
            )
            let discovered = try packageIdentifiers(in: expanded)
            guard Set(expectedPackageIds).isSubset(of: discovered) else {
                throw RuntimeError.outcome(
                    .stagingFailure,
                    message: "PKG expectedPackageIds do not match PackageInfo."
                )
            }
            let installer = ownedStage.appendingPathComponent("installer.pkg")
            try FileManager.default.copyItem(at: pkg, to: installer)
            try writeManifest(descriptor, to: ownedStage)
            return try finalizePKGStage(
                stageRoot: ownedStage,
                expanded: expanded,
                descriptor: descriptor
            )
        } catch {
            try? FileManager.default.removeItem(at: ownedStage)
            throw error
        }
    }

    func finalizePKGStage(
        stageRoot: URL,
        expanded: URL,
        descriptor: ReleaseDescriptor
    ) throws -> RuntimeStagedArtifact {
        let canonicalStageRoot = stageRoot.standardizedFileURL
        let canonicalExpanded = expanded.standardizedFileURL
        guard canonicalExpanded.lastPathComponent == "expanded-pkg",
              canonicalExpanded.deletingLastPathComponent() == canonicalStageRoot
        else {
            throw RuntimeError.outcome(
                .stagingFailure,
                message: "PKG verification cleanup escaped the owned stage."
            )
        }
        try FileManager.default.removeItem(at: expanded)
        return try finalize(
            stagedPath: stageRoot,
            stageRoot: stageRoot,
            descriptor: descriptor
        )
    }

    func installRequest(
        staged: RuntimeStagedUpdate,
        expectedPackageID: String,
        trustedReleasePublicKeys: [String: Data]
    ) throws -> MacInstallRequest {
        let verifiedStage = try MacVerifiedStage.loadAndVerify(
            stagedPath: staged.stagedPath,
            stageRoot: staged.stageRoot,
            expectedPackageID: expectedPackageID,
            trustedReleasePublicKeys: trustedReleasePublicKeys
        )
        guard verifiedStage.provenance.markerSHA256
            == staged.stageProvenanceSHA256,
            verifiedStage.provenance.marker.artifactSha256
                == staged.descriptor.artifact.sha256,
            verifiedStage.artifactKind == staged.descriptor.artifact.kind,
            verifiedStage.expectedPackageIDs == expectedPackageIDs(
                staged.descriptor
            ) else {
            throw RuntimeError.outcome(
                .installHandoffFailure,
                message: "Retained staged update identity changed."
            )
        }
        return MacInstallRequest(verifiedStage: verifiedStage)
    }

    private func validateApp(
        _ app: URL,
        expectedPackageId: String,
        expectedTeamIdentifier: String
    ) throws {
        let values = try app.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true,
              Bundle(url: app)?.bundleIdentifier == expectedPackageId
        else {
            throw RuntimeError.outcome(
                .packageIdentityMismatch,
                message: "Staged app bundle identity is invalid."
            )
        }
        if let applicationTrustValidator {
            try applicationTrustValidator(app, expectedTeamIdentifier)
            return
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        try run("/usr/bin/xcrun", ["stapler", "validate", app.path])
        let details = try run(
            "/usr/bin/codesign",
            ["-dv", "--verbose=4", app.path],
            capturesOutput: true
        )
        let lines = String(decoding: details, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        let teamIdentifier = lines.first { line in
            line.hasPrefix("TeamIdentifier=")
        }?.dropFirst("TeamIdentifier=".count)
        guard !expectedTeamIdentifier.isEmpty,
              teamIdentifier.map(String.init) == expectedTeamIdentifier
        else {
            throw RuntimeError.outcome(
                .stagingFailure,
                message: "Staged app TeamIdentifier does not match."
            )
        }
    }

    private func validateDescriptorIdentity(
        _ descriptor: ReleaseDescriptor,
        expectedPackageId: String,
        artifactKind: String
    ) throws {
        guard !expectedPackageId.isEmpty,
              descriptor.packageId == expectedPackageId,
              descriptor.platform == "macos",
              descriptor.artifact.kind == artifactKind
        else {
            throw RuntimeError.outcome(
                .packageIdentityMismatch,
                message: "Expected package identity does not match release."
            )
        }
    }

    private func exactTopLevelApp(in root: URL, named name: String) throws -> URL {
        let apps = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter { $0.pathExtension.lowercased() == "app" }
        let expected = root.appendingPathComponent(name).standardizedFileURL
        guard apps.count == 1,
              apps[0].standardizedFileURL == expected
        else {
            throw RuntimeError.outcome(
                .stagingFailure,
                message: "Artifact must contain exactly the configured app bundle."
            )
        }
        return apps[0]
    }

    func preflightZip(
        _ archive: URL,
        limits: RuntimeArchiveLimits
    ) throws {
        guard limits.maximumArchiveEntries > 0,
              limits.maximumUncompressedBytes > 0,
              limits.maximumSingleEntryBytes > 0
        else {
            throw RuntimeError.invalidConfiguration(
                "Archive limits must be positive."
            )
        }
        var entries: [String: Bool] = [:]
        var count: Int64 = 0
        var total: Int64 = 0
        for entry in try readZipCentralDirectory(
            archive,
            maximumEntries: UInt64(limits.maximumArchiveEntries)
        ) {
            guard entry.type == .regular || entry.type == .directory
                || entry.type == .symbolicLink else {
                throw unsafeArchive("ZIP links and special entries are unsafe.")
            }
            if entry.type == .symbolicLink {
                guard let target = entry.symbolicLinkTarget,
                      target == (try normalizeSafeArchivePath(target)) else {
                    throw unsafeArchive(
                        "ZIP symlink target is absolute or escapes staging."
                    )
                }
            }
            guard entry.uncompressedSize <= UInt64(Int64.max) else {
                throw unsafeArchive("ZIP entry size is invalid.")
            }
            let size = Int64(entry.uncompressedSize)
            let normalized = try normalizeSafeArchivePath(entry.path)
            let comparisonPath = normalized
                .precomposedStringWithCanonicalMapping
                .lowercased()
            let isDirectory = entry.type == .directory
            try checkArchiveConflict(
                path: comparisonPath,
                isDirectory: isDirectory,
                entries: &entries
            )
            let (nextCount, countOverflow) = count.addingReportingOverflow(1)
            guard !countOverflow,
                  nextCount <= limits.maximumArchiveEntries
            else {
                throw unsafeArchive("ZIP exceeds maximumArchiveEntries.")
            }
            count = nextCount
            guard size <= limits.maximumSingleEntryBytes else {
                throw unsafeArchive("ZIP exceeds maximumSingleEntryBytes.")
            }
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(size)
            guard !totalOverflow,
                  nextTotal <= limits.maximumUncompressedBytes
            else {
                throw unsafeArchive("ZIP exceeds maximumUncompressedBytes.")
            }
            total = nextTotal
        }
        guard count > 0 else {
            throw unsafeArchive("ZIP central directory is empty or unreadable.")
        }
    }

    private func ownedStage(in parent: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        }
        return try StageProvenance.createOwnedStage(parent: parent)
    }

    private func finalize(
        stagedPath: URL,
        stageRoot: URL,
        descriptor: ReleaseDescriptor
    ) throws -> RuntimeStagedArtifact {
        let nonce = String(
            stageRoot.lastPathComponent.dropFirst(updaterOwnedStagePrefix.count)
        )
        let state = try StageProvenance.write(
            stageRoot: stageRoot,
            nonce: nonce,
            packageID: descriptor.packageId,
            descriptorSHA256: try StageProvenance.canonicalJSONSHA256(
                descriptor.rawJSON
            ),
            artifactSHA256: descriptor.artifact.sha256
        )
        return RuntimeStagedArtifact(
            stagedPath: stagedPath,
            stageRoot: stageRoot,
            provenance: state
        )
    }

    private func expectedPackageIDs(
        _ descriptor: ReleaseDescriptor
    ) -> [String] {
        guard descriptor.artifact.kind == "pkgInstaller",
              let metadata = descriptor.install.normalizedJSON["macosPkg"]
                  as? [String: Any],
              let values = metadata["expectedPackageIds"] as? [String]
        else { return [] }
        return values
    }

    private func writeManifest(
        _ descriptor: ReleaseDescriptor,
        to directory: URL
    ) throws {
        let data = try JSONSerialization.data(
            withJSONObject: descriptor.rawJSON,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(
            to: directory.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            ),
            options: .atomic
        )
    }

    private func mountPoint(from plist: Data) throws -> URL {
        let value = try PropertyListSerialization.propertyList(
            from: plist,
            options: [],
            format: nil
        )
        let root = try dictionary(value)
        let entities = root["system-entities"] as? [[String: Any]] ?? []
        let mounts = entities.compactMap { $0["mount-point"] as? String }
        guard mounts.count == 1 else {
            throw RuntimeError.outcome(
                .stagingFailure,
                message: "DMG must expose exactly one mount point."
            )
        }
        return URL(fileURLWithPath: mounts[0])
    }

    private func packageIdentifiers(in root: URL) throws -> Set<String> {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        )
        var result = Set<String>()
        while let file = enumerator?.nextObject() as? URL {
            guard file.lastPathComponent == "PackageInfo" else { continue }
            let data = try Data(contentsOf: file)
            let document = try XMLDocument(data: data)
            if let identifier = document.rootElement()?
                .attribute(forName: "identifier")?.stringValue
            {
                result.insert(identifier)
            }
        }
        return result
    }

    @discardableResult
    private func run(
        _ executable: String,
        _ arguments: [String],
        capturesOutput: Bool = false
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        if capturesOutput {
            process.standardOutput = output
            process.standardError = output
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        let data = capturesOutput
            ? output.fileHandleForReading.readDataToEndOfFile()
            : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeError.outcome(
                .stagingFailure,
                message: "Native trust or staging command failed."
            )
        }
        return data
    }
}

private enum ZipCentralEntryType: Equatable {
    case regular
    case directory
    case symbolicLink
    case linkOrSpecial
}

private struct ZipCentralEntry {
    let path: String
    let uncompressedSize: UInt64
    let type: ZipCentralEntryType
    let symbolicLinkTarget: String?
}

private func readZipCentralDirectory(
    _ archive: URL,
    maximumEntries: UInt64
) throws -> [ZipCentralEntry] {
    let attributes = try FileManager.default.attributesOfItem(
        atPath: archive.path
    )
    guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
          size >= 22
    else {
        throw unsafeArchive("ZIP end-of-central-directory record is missing.")
    }
    let handle = try FileHandle(forReadingFrom: archive)
    defer { handle.closeFile() }
    let tailLength = Int(min(size, 65_557))
    let tailOffset = size - UInt64(tailLength)
    let tail = try readZipBytes(
        handle,
        offset: tailOffset,
        count: tailLength
    )
    var endIndex: Int?
    for index in stride(from: tail.count - 22, through: 0, by: -1) {
        guard zipUInt32(tail, index) == 0x0605_4b50 else { continue }
        let commentLength = Int(zipUInt16(tail, index + 20))
        if index + 22 + commentLength == tail.count {
            endIndex = index
            break
        }
    }
    guard let endIndex else {
        throw unsafeArchive("ZIP end-of-central-directory record is invalid.")
    }
    let endOffset = tailOffset + UInt64(endIndex)
    let disk = zipUInt16(tail, endIndex + 4)
    let centralDisk = zipUInt16(tail, endIndex + 6)
    let entriesOnDisk = zipUInt16(tail, endIndex + 8)
    let total16 = zipUInt16(tail, endIndex + 10)
    var totalEntries = UInt64(total16)
    var centralSize = UInt64(zipUInt32(tail, endIndex + 12))
    var centralOffset = UInt64(zipUInt32(tail, endIndex + 16))

    let needsZip64 = total16 == UInt16.max ||
        centralSize == UInt64(UInt32.max) ||
        centralOffset == UInt64(UInt32.max)
    if needsZip64 {
        guard endOffset >= 20 else {
            throw unsafeArchive("ZIP64 locator is missing.")
        }
        let locator = try readZipBytes(
            handle,
            offset: endOffset - 20,
            count: 20
        )
        guard zipUInt32(locator, 0) == 0x0706_4b50,
              zipUInt32(locator, 4) == 0,
              zipUInt32(locator, 16) == 1
        else {
            throw unsafeArchive("Multi-disk ZIP64 archives are unsupported.")
        }
        let zip64Offset = zipUInt64(locator, 8)
        let zip64 = try readZipBytes(
            handle,
            offset: zip64Offset,
            count: 56
        )
        guard zipUInt32(zip64, 0) == 0x0606_4b50,
              zipUInt64(zip64, 4) >= 44,
              zipUInt32(zip64, 16) == 0,
              zipUInt32(zip64, 20) == 0,
              zipUInt64(zip64, 24) == zipUInt64(zip64, 32)
        else {
            throw unsafeArchive("ZIP64 central directory is invalid.")
        }
        totalEntries = zipUInt64(zip64, 32)
        centralSize = zipUInt64(zip64, 40)
        centralOffset = zipUInt64(zip64, 48)
    } else {
        guard disk == 0,
              centralDisk == 0,
              entriesOnDisk == total16
        else {
            throw unsafeArchive("Multi-disk ZIP archives are unsupported.")
        }
    }
    guard totalEntries > 0,
          totalEntries <= maximumEntries,
          totalEntries <= UInt64(Int.max)
    else {
        throw unsafeArchive("ZIP exceeds maximumArchiveEntries.")
    }
    let centralEnd = try zipCheckedAdd(centralOffset, centralSize)
    guard centralEnd <= size else {
        throw unsafeArchive("ZIP central directory escapes the archive.")
    }

    var result: [ZipCentralEntry] = []
    result.reserveCapacity(Int(totalEntries))
    var cursor = centralOffset
    var localOffsets = Set<UInt64>()
    for _ in 0 ..< Int(totalEntries) {
        let header = try readZipBytes(handle, offset: cursor, count: 46)
        guard zipUInt32(header, 0) == 0x0201_4b50 else {
            throw unsafeArchive("ZIP central directory entry is invalid.")
        }
        let versionMadeBy = zipUInt16(header, 4)
        let flags = zipUInt16(header, 8)
        guard flags & 0x1 == 0 else {
            throw unsafeArchive("Encrypted ZIP entries are unsupported.")
        }
        let filenameLength = Int(zipUInt16(header, 28))
        let extraLength = Int(zipUInt16(header, 30))
        let commentLength = Int(zipUInt16(header, 32))
        guard filenameLength > 0, zipUInt16(header, 34) == 0 else {
            throw unsafeArchive("ZIP entry uses an invalid path or disk.")
        }
        let variableLength = filenameLength + extraLength + commentLength
        let next = try zipCheckedAdd(
            cursor,
            UInt64(46 + variableLength)
        )
        guard next <= centralEnd else {
            throw unsafeArchive("ZIP central directory entry is truncated.")
        }
        let variable = try readZipBytes(
            handle,
            offset: cursor + 46,
            count: variableLength
        )
        let filenameData = Data(variable.prefix(filenameLength))
        guard let path = String(data: filenameData, encoding: .utf8) else {
            throw unsafeArchive("ZIP entry path is not valid UTF-8.")
        }
        let extraStart = filenameLength
        let extra = Data(
            variable[extraStart ..< extraStart + extraLength]
        )
        let resolved = try resolveZip64CentralValues(
            extra,
            uncompressed32: zipUInt32(header, 24),
            compressed32: zipUInt32(header, 20),
            localOffset32: zipUInt32(header, 42),
            diskStart16: zipUInt16(header, 34)
        )
        let compressionMethod = zipUInt16(header, 10)
        guard resolved.diskStart == 0,
              localOffsets.insert(resolved.localOffset).inserted
        else {
            throw unsafeArchive(
                "ZIP uses multiple disks or duplicate local entries."
            )
        }
        let localHeader = try readZipBytes(
            handle,
            offset: resolved.localOffset,
            count: 30
        )
        let localFilenameLength = Int(zipUInt16(localHeader, 26))
        let localExtraLength = Int(zipUInt16(localHeader, 28))
        let localVariableLength = localFilenameLength + localExtraLength
        let localVariableOffset = try zipCheckedAdd(
            resolved.localOffset,
            30
        )
        let localVariable = try readZipBytes(
            handle,
            offset: localVariableOffset,
            count: localVariableLength
        )
        let localFilename = Data(localVariable.prefix(localFilenameLength))
        guard zipUInt32(localHeader, 0) == 0x0403_4b50,
              zipUInt16(localHeader, 6) == flags,
              zipUInt16(localHeader, 8) == compressionMethod,
              localFilename == filenameData
        else {
            throw unsafeArchive(
                "ZIP local and central directory entries do not match."
            )
        }
        let localDataOffset = try zipCheckedAdd(
            resolved.localOffset,
            UInt64(30 + localVariableLength)
        )
        let localDataEnd = try zipCheckedAdd(
            localDataOffset,
            resolved.compressedSize
        )
        guard localDataEnd <= size else {
            throw unsafeArchive("ZIP entry data escapes the archive.")
        }
        let externalAttributes = zipUInt32(header, 38)
        let hostSystem = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
        let type = zipEntryType(
            path: path,
            hostSystem: hostSystem,
            externalAttributes: externalAttributes
        )
        var symbolicLinkTarget: String?
        if type == .symbolicLink {
            guard compressionMethod == 0,
                  resolved.compressedSize == resolved.uncompressedSize,
                  resolved.uncompressedSize > 0,
                  resolved.uncompressedSize <= 4096 else {
                throw unsafeArchive(
                    "ZIP symlink entry must use a bounded stored target."
                )
            }
            let targetData = try readZipBytes(
                handle,
                offset: localDataOffset,
                count: Int(resolved.uncompressedSize)
            )
            guard let target = String(data: targetData, encoding: .utf8),
                  target == (try normalizeSafeArchivePath(target)) else {
                throw unsafeArchive(
                    "ZIP symlink target is invalid or escapes staging."
                )
            }
            symbolicLinkTarget = target
        }
        result.append(
            ZipCentralEntry(
                path: path,
                uncompressedSize: resolved.uncompressedSize,
                type: type,
                symbolicLinkTarget: symbolicLinkTarget
            )
        )
        cursor = next
    }
    guard cursor <= centralEnd else {
        throw unsafeArchive("ZIP central directory size is invalid.")
    }
    return result
}

private func zipEntryType(
    path: String,
    hostSystem: UInt8,
    externalAttributes: UInt32
) -> ZipCentralEntryType {
    if hostSystem == 3 || hostSystem == 19 {
        let mode = externalAttributes >> 16
        switch mode & 0o170000 {
        case 0:
            return path.hasSuffix("/") ? .directory : .regular
        case 0o040000:
            return .directory
        case 0o100000:
            return .regular
        case 0o120000:
            return .symbolicLink
        default:
            return .linkOrSpecial
        }
    }
    if path.hasSuffix("/") || externalAttributes & 0x10 != 0 {
        return .directory
    }
    return .regular
}

private struct Zip64CentralValues {
    let uncompressedSize: UInt64
    let compressedSize: UInt64
    let localOffset: UInt64
    let diskStart: UInt32
}

private func resolveZip64CentralValues(
    _ extra: Data,
    uncompressed32: UInt32,
    compressed32: UInt32,
    localOffset32: UInt32,
    diskStart16: UInt16
) throws -> Zip64CentralValues {
    let requiresZip64 = uncompressed32 == UInt32.max ||
        compressed32 == UInt32.max ||
        localOffset32 == UInt32.max ||
        diskStart16 == UInt16.max
    if !requiresZip64 {
        return Zip64CentralValues(
            uncompressedSize: UInt64(uncompressed32),
            compressedSize: UInt64(compressed32),
            localOffset: UInt64(localOffset32),
            diskStart: UInt32(diskStart16)
        )
    }
    var cursor = 0
    while cursor + 4 <= extra.count {
        let identifier = zipUInt16(extra, cursor)
        let length = Int(zipUInt16(extra, cursor + 2))
        let next = cursor + 4 + length
        guard next <= extra.count else {
            throw unsafeArchive("ZIP extra field is truncated.")
        }
        if identifier == 0x0001 {
            var valueCursor = cursor + 4
            let end = next
            func read64() throws -> UInt64 {
                guard valueCursor + 8 <= end else {
                    throw unsafeArchive("ZIP64 field is truncated.")
                }
                let value = zipUInt64(extra, valueCursor)
                valueCursor += 8
                return value
            }
            func read32() throws -> UInt32 {
                guard valueCursor + 4 <= end else {
                    throw unsafeArchive("ZIP64 field is truncated.")
                }
                let value = zipUInt32(extra, valueCursor)
                valueCursor += 4
                return value
            }
            let uncompressed = uncompressed32 == UInt32.max
                ? try read64()
                : UInt64(uncompressed32)
            let compressed = compressed32 == UInt32.max
                ? try read64()
                : UInt64(compressed32)
            let localOffset = localOffset32 == UInt32.max
                ? try read64()
                : UInt64(localOffset32)
            let diskStart = diskStart16 == UInt16.max
                ? try read32()
                : UInt32(diskStart16)
            return Zip64CentralValues(
                uncompressedSize: uncompressed,
                compressedSize: compressed,
                localOffset: localOffset,
                diskStart: diskStart
            )
        }
        cursor = next
    }
    throw unsafeArchive("ZIP64 size field is missing.")
}

private func readZipBytes(
    _ handle: FileHandle,
    offset: UInt64,
    count: Int
) throws -> Data {
    handle.seek(toFileOffset: offset)
    let data = handle.readData(ofLength: count)
    guard data.count == count else {
        throw unsafeArchive("ZIP structure is truncated.")
    }
    return data
}

private func zipCheckedAdd(_ first: UInt64, _ second: UInt64) throws -> UInt64 {
    let (result, overflow) = first.addingReportingOverflow(second)
    guard !overflow else {
        throw unsafeArchive("ZIP offset overflowed.")
    }
    return result
}

private func zipUInt16(_ data: Data, _ offset: Int) -> UInt16 {
    return UInt16(data[offset]) |
        UInt16(data[offset + 1]) << 8
}

private func zipUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    return UInt32(zipUInt16(data, offset)) |
        UInt32(zipUInt16(data, offset + 2)) << 16
}

private func zipUInt64(_ data: Data, _ offset: Int) -> UInt64 {
    return UInt64(zipUInt32(data, offset)) |
        UInt64(zipUInt32(data, offset + 4)) << 32
}

func normalizeSafeArchivePath(_ input: String) throws -> String {
    guard !input.isEmpty, !input.contains("\0") else {
        throw unsafeArchive("ZIP entry path is empty or contains NUL.")
    }
    let normalized = input.replacingOccurrences(of: "\\", with: "/")
    guard !normalized.hasPrefix("/"),
          normalized.range(
              of: "^[A-Za-z]:",
              options: .regularExpression
          ) == nil
    else {
        throw unsafeArchive("ZIP entry path is absolute.")
    }
    var segments: [Substring] = []
    for segment in normalized.split(
        separator: "/",
        omittingEmptySubsequences: true
    ) {
        if segment == ".." {
            throw unsafeArchive("ZIP entry path traverses staging.")
        }
        if segment != "." {
            guard !segment.contains(":") else {
                throw unsafeArchive("ZIP entry path contains a drive prefix.")
            }
            segments.append(segment)
        }
    }
    guard !segments.isEmpty else {
        throw unsafeArchive("ZIP entry path is empty.")
    }
    return segments.joined(separator: "/")
}

private func checkArchiveConflict(
    path: String,
    isDirectory: Bool,
    entries: inout [String: Bool]
) throws {
    if entries[path] != nil {
        throw unsafeArchive("ZIP contains a duplicate archive entry.")
    }
    let components = path.split(separator: "/")
    if components.count > 1 {
        for count in 1 ..< components.count {
            let parent = components.prefix(count).joined(separator: "/")
            if entries[parent] == false {
                throw unsafeArchive("ZIP contains a file/directory conflict.")
            }
        }
    }
    if !isDirectory {
        let prefix = path + "/"
        if entries.keys.contains(where: { $0.hasPrefix(prefix) }) {
            throw unsafeArchive("ZIP contains a file/directory conflict.")
        }
    }
    entries[path] = isDirectory
}

private func unsafeArchive(_ message: String) -> RuntimeError {
    return RuntimeError.outcome(.unsafeArchive, message: message)
}

private func dictionary(_ value: Any?) throws -> [String: Any] {
    guard let dictionary = value as? [String: Any] else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected artifact install metadata."
        )
    }
    return dictionary
}

private func string(_ source: [String: Any], _ key: String) throws -> String {
    guard let value = source[key] as? String, !value.isEmpty else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected artifact metadata string \(key)."
        )
    }
    return value
}

private func strings(_ source: [String: Any], _ key: String) throws -> [String] {
    guard let values = source[key] as? [String], !values.isEmpty else {
        throw RuntimeError.outcome(
            .invalidDescriptor,
            message: "Expected artifact metadata list \(key)."
        )
    }
    return values
}
