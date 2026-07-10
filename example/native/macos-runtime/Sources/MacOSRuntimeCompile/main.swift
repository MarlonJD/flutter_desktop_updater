import DesktopUpdaterKit
import Foundation

@main
struct MacOSRuntimeSmoke {
    static func main() async throws {
        let arguments = try Arguments(CommandLine.arguments)
        guard arguments.isSmoke else {
            let configuration = try RuntimeConfiguration(
                appArchiveUrl: URL(
                    string: "https://updates.example.test/app-archive.json"
                )!,
                expectedPackageId: "com.example.native-runtime-smoke",
                currentVersion: "2.7.0",
                currentBuildNumber: 270,
                currentUpdaterVersion: "2.7.0",
                platform: "macos",
                installationIdentity: "external-swiftpm-consumer",
                pinnedPublicKeysById: [
                    "native-runtime-smoke-stable": Data(repeating: 1, count: 32)
                ]
            )
            let client = UpdateClient(configuration: configuration)
            print(
                "DesktopUpdaterKit runtime API compiled: " +
                    RuntimeOutcome.noUpdate.rawValue +
                    " via \(type(of: client))"
            )
            return
        }

        let publicKey = try requiredData(
            base64: arguments.value("--public-key-base64")
        )
        let packageId = arguments.value("--package-id")
        let smokeRoot = URL(
            fileURLWithPath: arguments.value("--smoke-root"),
            isDirectory: true
        )
        let diagnosticsLog = arguments.value("--diagnostics-log")
        let bundlePath = arguments.value("--bundle-path")
        let allowUnsigned = arguments.has("--allow-unsigned-updates")
        let configuration = try RuntimeConfiguration(
            appArchiveUrl: try requiredURL(
                arguments.value("--app-archive-url")
            ),
            expectedPackageId: packageId,
            currentVersion: "2.7.0",
            currentBuildNumber: 270,
            currentUpdaterVersion: "2.7.0",
            platform: "macos",
            installationIdentity: "macos-native-runtime-smoke",
            pinnedPublicKeysById: [
                "native-runtime-smoke-stable": publicKey
            ]
        )
        let client = UpdateClient(configuration: configuration)
        let check = await client.checkForUpdate()
        guard check.outcome == .updateAvailable else {
            throw SmokeFailure("checkForUpdate: \(check.outcome.rawValue) \(check.message)")
        }
        let staged = try await client.downloadVerifyAndStage(
            check,
            downloadDirectory: smokeRoot.appendingPathComponent("downloads"),
            stagingRoot: smokeRoot.appendingPathComponent("staging"),
            expectedTeamIdentifier: arguments.optionalValue(
                "--expected-team-identifier"
            ) ?? "",
            allowUnsignedUpdates: allowUnsigned
        ).get()
        try writeDiagnostics(
            client.diagnostics.redactedLogLines(),
            to: smokeRoot.appendingPathComponent("runtime-diagnostics.log")
        )
        try client.installAndRelaunch(
            staged,
            diagnosticsLogPath: diagnosticsLog,
            bundlePath: bundlePath,
            allowUnsignedUpdates: allowUnsigned
        )
        print(
            "installAndRelaunch scheduled \(staged.descriptor.version) " +
                "from \(staged.descriptor.artifact.kind)"
        )
    }
}

private struct Arguments {
    private let values: [String]

    init(_ values: [String]) throws {
        self.values = values
        if isSmoke {
            for option in [
                "--app-archive-url",
                "--public-key-base64",
                "--package-id",
                "--smoke-root",
                "--diagnostics-log",
                "--bundle-path",
            ] where optionalValue(option) == nil {
                throw SmokeFailure("Missing required argument \(option).")
            }
        }
    }

    var isSmoke: Bool { values.contains("--smoke") }
    func has(_ option: String) -> Bool { values.contains(option) }

    func value(_ option: String) -> String {
        optionalValue(option)!
    }

    func optionalValue(_ option: String) -> String? {
        guard let index = values.firstIndex(of: option),
              values.indices.contains(index + 1)
        else { return nil }
        return values[index + 1]
    }
}

private struct SmokeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private func requiredURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.scheme != nil else {
        throw SmokeFailure("Smoke app-archive URL must be absolute.")
    }
    return url
}

private func requiredData(base64: String) throws -> Data {
    guard let data = Data(base64Encoded: base64), data.count == 32 else {
        throw SmokeFailure("Smoke Ed25519 public key must contain 32 bytes.")
    }
    return data
}

private func writeDiagnostics(_ lines: [String], to file: URL) throws {
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try (lines.joined(separator: "\n") + "\n").write(
        to: file,
        atomically: true,
        encoding: .utf8
    )
}
