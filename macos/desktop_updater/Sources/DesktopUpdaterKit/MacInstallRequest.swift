import Foundation

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
