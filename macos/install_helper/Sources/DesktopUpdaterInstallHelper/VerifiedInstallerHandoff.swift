import Foundation

enum MacVerifiedInstallerKind: Equatable {
    case pkg
    case dmgInstallerApplication
}

struct MacVerifiedInstallerExpectation: Equatable {
    let installerURL: URL
    let kind: MacVerifiedInstallerKind
    let packageIdentifier: String
    let expectedVersion: String
    let designatedRequirement: String
    let artifactSHA256: String
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
    ) throws

    func verifyInstalledPackage(
        identifier: String,
        version: String
    ) throws
}

protocol MacFixedInstallerRunning {
    func launchVerifiedInstaller(
        at url: URL,
        kind: MacVerifiedInstallerKind
    ) throws -> String
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
        guard !expectation.packageIdentifier.isEmpty,
              !expectation.expectedVersion.isEmpty,
              !expectation.designatedRequirement.isEmpty,
              expectation.artifactSHA256.count == 64,
              expectation.artifactSHA256.allSatisfy({
                  $0.isNumber || ("a" ... "f").contains($0)
              }) else {
            throw MacVerifiedInstallerHandoffError.invalidExpectation
        }
        try verifier.verifyInstaller(expectation)
        let transactionIdentity = try runner.launchVerifiedInstaller(
            at: expectation.installerURL,
            kind: expectation.kind
        )
        guard !transactionIdentity.isEmpty else {
            throw MacVerifiedInstallerHandoffError
                .emptyProviderTransactionIdentity
        }
        try verifier.verifyInstalledPackage(
            identifier: expectation.packageIdentifier,
            version: expectation.expectedVersion
        )
        return MacProviderTransaction(
            identity: transactionIdentity,
            state: .completed
        )
    }

    func recover(
        _ expectation: MacVerifiedInstallerExpectation,
        transactionIdentity: String
    ) -> MacProviderTransaction {
        guard !transactionIdentity.isEmpty else {
            return .init(identity: "", state: .manualActionRequired)
        }
        do {
            try verifier.verifyInstalledPackage(
                identifier: expectation.packageIdentifier,
                version: expectation.expectedVersion
            )
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
}

final class MacPlatformInstallerRunner: MacFixedInstallerRunning {
    func launchVerifiedInstaller(
        at url: URL,
        kind: MacVerifiedInstallerKind
    ) throws -> String {
        let process = Process()
        switch kind {
        case .pkg:
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
            process.arguments = ["-pkg", url.path, "-target", "/"]
        case .dmgInstallerApplication:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-W", "-a", url.path]
        }
        let identity = UUID().uuidString.lowercased()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MacVerifiedInstallerHandoffError.installerFailed(
                process.terminationStatus
            )
        }
        return identity
    }
}
