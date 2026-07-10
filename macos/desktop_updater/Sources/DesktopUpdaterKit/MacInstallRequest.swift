import Foundation

public struct MacInstallRequest: Sendable {
    public let stagingPath: String?
    public let allowUnsignedUpdates: Bool
    public let diagnosticsLogPath: String?
    public let currentProcessIdentifier: Int32
    public let bundlePath: String

    public init(
        stagingPath: String?,
        allowUnsignedUpdates: Bool,
        diagnosticsLogPath: String?,
        currentProcessIdentifier: Int32,
        bundlePath: String
    ) {
        self.stagingPath = stagingPath
        self.allowUnsignedUpdates = allowUnsignedUpdates
        self.diagnosticsLogPath = diagnosticsLogPath
        self.currentProcessIdentifier = currentProcessIdentifier
        self.bundlePath = bundlePath
    }
}
