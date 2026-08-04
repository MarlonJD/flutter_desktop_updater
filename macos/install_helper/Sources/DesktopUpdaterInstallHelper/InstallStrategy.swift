import Foundation

enum NativeInstallStrategy: String, CaseIterable {
    case directoryReplace
    case singleFileReplace
    case verifiedInstallerHandoff
    case systemPackageTransaction
    case externalManagedRefresh
}

enum NativeInstallProvider: String, CaseIterable {
    case platformDirectory
    case platformFile
    case macosInstaller
    case windowsInno
    case apt
    case dnf
    case flatpak
    case snap
}

struct InstallStrategyCapability: Hashable {
    let strategy: NativeInstallStrategy
    let provider: NativeInstallProvider
}

struct InstallStrategyRequest {
    let strategy: NativeInstallStrategy
    let provider: NativeInstallProvider
    let brokerAuthenticated: Bool
    let targetRootOwned: Bool
    let callerArguments: [String]
    let directRevisionMutation: Bool
    let dangerousSideload: Bool

    init(
        strategy: NativeInstallStrategy,
        provider: NativeInstallProvider,
        brokerAuthenticated: Bool = false,
        targetRootOwned: Bool = false,
        callerArguments: [String] = [],
        directRevisionMutation: Bool = false,
        dangerousSideload: Bool = false
    ) {
        self.strategy = strategy
        self.provider = provider
        self.brokerAuthenticated = brokerAuthenticated
        self.targetRootOwned = targetRootOwned
        self.callerArguments = callerArguments
        self.directRevisionMutation = directRevisionMutation
        self.dangerousSideload = dangerousSideload
    }
}

enum InstallStrategySelectionError: Error, Equatable {
    case unsupportedPair
    case policyDenied
    case protocolCapabilityMissing
    case callerArgumentsRejected
    case directRevisionMutationRejected
    case dangerousSideloadRejected
    case rootFileRequiresBroker
}

struct MacInstallStrategySelector {
    private static let supported: Set<InstallStrategyCapability> = [
        .init(strategy: .directoryReplace, provider: .platformDirectory),
        .init(strategy: .singleFileReplace, provider: .platformFile),
        .init(
            strategy: .verifiedInstallerHandoff,
            provider: .macosInstaller
        ),
    ]

    private let policyCapabilities: Set<InstallStrategyCapability>
    private let protocolCapabilities: Set<InstallStrategyCapability>

    init(
        policyCapabilities: Set<InstallStrategyCapability>,
        protocolCapabilities: Set<InstallStrategyCapability>
    ) {
        self.policyCapabilities = policyCapabilities
        self.protocolCapabilities = protocolCapabilities
    }

    func select(
        _ request: InstallStrategyRequest
    ) throws -> InstallStrategyCapability {
        let requested = InstallStrategyCapability(
            strategy: request.strategy,
            provider: request.provider
        )
        guard Self.supported.contains(requested) else {
            throw InstallStrategySelectionError.unsupportedPair
        }
        guard request.callerArguments.isEmpty else {
            throw InstallStrategySelectionError.callerArgumentsRejected
        }
        guard !request.directRevisionMutation else {
            throw InstallStrategySelectionError
                .directRevisionMutationRejected
        }
        guard !request.dangerousSideload else {
            throw InstallStrategySelectionError.dangerousSideloadRejected
        }
        if request.strategy == .singleFileReplace,
           request.targetRootOwned,
           !request.brokerAuthenticated {
            throw InstallStrategySelectionError.rootFileRequiresBroker
        }
        guard policyCapabilities.contains(requested) else {
            throw InstallStrategySelectionError.policyDenied
        }
        guard protocolCapabilities.contains(requested) else {
            throw InstallStrategySelectionError.protocolCapabilityMissing
        }
        return requested
    }
}

struct MacFileStrategyExecutor {
    func execute(
        capability: InstallStrategyCapability,
        transaction: MacFileTransaction
    ) throws -> MacFileTransactionResult {
        guard capability == .init(
            strategy: .directoryReplace,
            provider: .platformDirectory
        ) || capability == .init(
            strategy: .singleFileReplace,
            provider: .platformFile
        ) else {
            throw InstallStrategySelectionError.unsupportedPair
        }
        return try transaction.execute()
    }
}
