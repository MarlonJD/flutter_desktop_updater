import CommonCrypto
import Foundation

public let stageProvenanceFileName =
    ".desktop_updater_stage_provenance.json"
public let updaterOwnedStagePrefix = "desktop_updater_stage_"

public struct StageProvenanceEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: String
    public let length: Int64
    public let sha256: String?
    public let target: String?
}

public struct StageProvenanceMarker: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let nonce: String
    public let packageId: String
    public let descriptorSha256: String
    public let artifactSha256: String
    public let entries: [StageProvenanceEntry]
}

public struct StageProvenanceState: Sendable {
    public let marker: StageProvenanceMarker
    public let markerSHA256: String
}

public enum StageProvenance {
    public static func createOwnedStage(
        parent: URL,
        nonce: UUID = UUID()
    ) throws -> URL {
        let values = try parent.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw failure("Staging parent must be a real directory.")
        }
        let requestedParent = parent.standardizedFileURL
        guard requestedParent.deletingLastPathComponent() != requestedParent else {
            throw failure("Filesystem roots cannot be staging parents.")
        }
        let nonceText = nonce.uuidString.lowercased()
        guard validNonce(nonceText) else {
            throw failure("Owned staging nonce is invalid.")
        }
        let child = requestedParent.appendingPathComponent(
            updaterOwnedStagePrefix + nonceText,
            isDirectory: true
        )
        guard child.deletingLastPathComponent() == requestedParent else {
            throw failure("Owned staging child escapes its parent.")
        }
        try FileManager.default.createDirectory(
            at: child,
            withIntermediateDirectories: false
        )
        let canonicalParent = requestedParent.resolvingSymlinksInPath()
        let canonicalChild = child.resolvingSymlinksInPath()
        guard canonicalChild.deletingLastPathComponent() == canonicalParent else {
            try? FileManager.default.removeItem(at: child)
            throw failure("Owned staging child escapes its canonical parent.")
        }
        return child
    }

    public static func write(
        stageRoot: URL,
        nonce: String,
        packageID: String,
        descriptorSHA256: String,
        artifactSHA256: String
    ) throws -> StageProvenanceState {
        try validateRoot(stageRoot, nonce: nonce)
        guard !packageID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              validSHA256(descriptorSHA256),
              validSHA256(artifactSHA256)
        else {
            throw failure("Stage provenance metadata is invalid.")
        }
        let marker = StageProvenanceMarker(
            schemaVersion: 1,
            nonce: nonce,
            packageId: packageID,
            descriptorSha256: descriptorSHA256,
            artifactSha256: artifactSHA256,
            entries: try inventory(stageRoot)
        )
        let bytes = try canonicalBytes(marker)
        try bytes.write(
            to: stageRoot.appendingPathComponent(stageProvenanceFileName),
            options: .withoutOverwriting
        )
        return StageProvenanceState(
            marker: marker,
            markerSHA256: sha256(bytes)
        )
    }

    public static func read(stageRoot: URL) throws -> StageProvenanceState {
        let markerURL = stageRoot.appendingPathComponent(
            stageProvenanceFileName
        )
        let markerValues = try markerURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true
        else {
            throw failure("Stage provenance marker is missing or unsafe.")
        }
        let bytes = try Data(contentsOf: markerURL)
        let marker = try JSONDecoder().decode(
            StageProvenanceMarker.self,
            from: bytes
        )
        try validate(marker)
        guard bytes == (try canonicalBytes(marker)) else {
            throw failure("Stage provenance marker is not canonical.")
        }
        try validateRoot(stageRoot, nonce: marker.nonce)
        return StageProvenanceState(
            marker: marker,
            markerSHA256: sha256(bytes)
        )
    }

    @discardableResult
    public static func verify(
        stageRoot: URL,
        expectedMarkerSHA256: String
    ) throws -> StageProvenanceMarker {
        guard validSHA256(expectedMarkerSHA256) else {
            throw failure("Expected stage provenance SHA-256 is invalid.")
        }
        let state = try read(stageRoot: stageRoot)
        guard state.markerSHA256 == expectedMarkerSHA256 else {
            throw failure("Stage provenance marker digest changed.")
        }
        guard try inventory(stageRoot) == state.marker.entries else {
            throw failure("Staged update inventory changed.")
        }
        return state.marker
    }

    public static func removeOwnedStage(
        parent: URL,
        stageRoot: URL,
        nonce: String
    ) throws {
        let canonicalParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalRoot = stageRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalRoot.deletingLastPathComponent() == canonicalParent else {
            throw failure("Owned stage cleanup path escapes parent.")
        }
        let state = try read(stageRoot: stageRoot)
        guard state.marker.nonce == nonce else {
            throw failure("Owned stage cleanup nonce changed.")
        }
        _ = try verify(
            stageRoot: stageRoot,
            expectedMarkerSHA256: state.markerSHA256
        )
        try FileManager.default.removeItem(at: stageRoot)
    }

    public static func canonicalJSONSHA256(_ value: Any) throws -> String {
        let bytes = try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
        return sha256(try canonicalSlashBytes(bytes))
    }

    private static func inventory(_ stageRoot: URL) throws
        -> [StageProvenanceEntry]
    {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: stageRoot,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw failure("Unable to enumerate staged update.")
        }
        var entries: [StageProvenanceEntry] = []
        while let entry = enumerator.nextObject() as? URL {
            let relative = relativePath(entry, from: stageRoot)
            try validateRelative(relative, field: "inventory path")
            if relative == stageProvenanceFileName { continue }
            let values = try entry.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                let target = try FileManager.default.destinationOfSymbolicLink(
                    atPath: entry.path
                ).replacingOccurrences(of: "\\", with: "/")
                try validateRelative(target, field: "symlink target")
                let resolved = entry.deletingLastPathComponent()
                    .appendingPathComponent(target)
                    .standardizedFileURL
                let root = stageRoot.standardizedFileURL
                guard resolved.path == root.path ||
                    resolved.path.hasPrefix(root.path + "/")
                else {
                    throw failure("Staged symlink escapes stage root.")
                }
                entries.append(StageProvenanceEntry(
                    path: relative,
                    kind: "symlink",
                    length: 0,
                    sha256: nil,
                    target: target
                ))
            } else if values.isDirectory == true {
                entries.append(StageProvenanceEntry(
                    path: relative,
                    kind: "directory",
                    length: 0,
                    sha256: nil,
                    target: nil
                ))
            } else if values.isRegularFile == true {
                let bytes = try Data(contentsOf: entry, options: .mappedIfSafe)
                entries.append(StageProvenanceEntry(
                    path: relative,
                    kind: "file",
                    length: Int64(bytes.count),
                    sha256: sha256(bytes),
                    target: nil
                ))
            } else {
                throw failure("Unsupported staged filesystem entry.")
            }
        }
        if let enumerationError { throw enumerationError }
        return entries.sorted { utf8Less($0.path, $1.path) }
    }

    private static func validate(_ marker: StageProvenanceMarker) throws {
        guard marker.schemaVersion == 1,
              validNonce(marker.nonce),
              !marker.packageId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              validSHA256(marker.descriptorSha256),
              validSHA256(marker.artifactSha256)
        else {
            throw failure("Stage provenance identity is invalid.")
        }
        var seen = Set<String>()
        var previous: String?
        for entry in marker.entries {
            try validateRelative(entry.path, field: "entry path")
            guard seen.insert(entry.path).inserted else {
                throw failure("Stage provenance contains duplicate paths.")
            }
            if let previous, !utf8Less(previous, entry.path) {
                throw failure("Stage provenance entries are not sorted.")
            }
            previous = entry.path
            switch entry.kind {
            case "file":
                guard entry.length >= 0,
                      entry.sha256.map(validSHA256) == true,
                      entry.target == nil
                else { throw failure("Provenance file entry is invalid.") }
            case "directory":
                guard entry.length == 0,
                      entry.sha256 == nil,
                      entry.target == nil
                else { throw failure("Provenance directory entry is invalid.") }
            case "symlink":
                guard entry.length == 0,
                      entry.sha256 == nil,
                      let target = entry.target
                else { throw failure("Provenance symlink entry is invalid.") }
                try validateRelative(target, field: "symlink target")
            default:
                throw failure("Unsupported provenance entry kind.")
            }
        }
    }

    private static func validateRoot(_ root: URL, nonce: String) throws {
        let values = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              validNonce(nonce),
              root.lastPathComponent == updaterOwnedStagePrefix + nonce
        else {
            throw failure("Stage root is not bound to its marker nonce.")
        }
    }

    private static func validateRelative(_ value: String, field: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasSuffix("/"),
              !value.contains("\\"),
              value.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil,
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else {
            throw failure("Invalid \(field): \(value)")
        }
    }

    private static func relativePath(_ entry: URL, from root: URL) -> String {
        String(entry.standardizedFileURL.path.dropFirst(
            root.standardizedFileURL.path.count + 1
        ))
    }

    private static func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try canonicalSlashBytes(encoder.encode(value))
    }

    private static func canonicalSlashBytes(_ data: Data) throws -> Data {
        guard let json = String(data: data, encoding: .utf8) else {
            throw failure("Canonical stage provenance JSON is not UTF-8.")
        }
        return Data(json.replacingOccurrences(of: "\\/", with: "/").utf8)
    }

    private static func sha256(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        _ = CC_SHA256_Init(&context)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = min(bytes.count - offset, Int(CC_LONG.max))
                _ = CC_SHA256_Update(
                    &context,
                    baseAddress.advanced(by: offset),
                    CC_LONG(count)
                )
                offset += count
            }
        }
        var digest = [UInt8](
            repeating: 0,
            count: Int(CC_SHA256_DIGEST_LENGTH)
        )
        _ = CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validNonce(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func utf8Less(_ left: String, _ right: String) -> Bool {
        left.utf8.lexicographicallyPrecedes(right.utf8)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "DesktopUpdaterKit.StageProvenance",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

public struct MacInstallRequest: Sendable {
    public let stagingPath: String?
    public let allowUnsignedUpdates: Bool
    public let diagnosticsLogPath: String?
    public let currentProcessIdentifier: Int32
    public let bundlePath: String
    public let stageRoot: String?
    public let expectedProvenanceSHA256: String?
    public let artifactKind: String?
    public let expectedArtifactSHA256: String?
    public let expectedPackageIDs: [String]
    public let provenanceEntries: [StageProvenanceEntry]

    public init(
        stagingPath: String?,
        allowUnsignedUpdates: Bool,
        diagnosticsLogPath: String?,
        currentProcessIdentifier: Int32,
        bundlePath: String,
        stageRoot: String? = nil,
        expectedProvenanceSHA256: String? = nil,
        artifactKind: String? = nil,
        expectedArtifactSHA256: String? = nil,
        expectedPackageIDs: [String] = [],
        provenanceEntries: [StageProvenanceEntry] = []
    ) {
        self.stagingPath = stagingPath
        self.allowUnsignedUpdates = allowUnsignedUpdates
        self.diagnosticsLogPath = diagnosticsLogPath
        self.currentProcessIdentifier = currentProcessIdentifier
        self.bundlePath = bundlePath
        self.stageRoot = stageRoot
        self.expectedProvenanceSHA256 = expectedProvenanceSHA256
        self.artifactKind = artifactKind
        self.expectedArtifactSHA256 = expectedArtifactSHA256
        self.expectedPackageIDs = expectedPackageIDs
        self.provenanceEntries = provenanceEntries
    }
}
