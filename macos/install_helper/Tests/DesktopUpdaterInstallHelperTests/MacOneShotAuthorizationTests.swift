import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacOneShotAuthorizationTests: XCTestCase {
    func testRetainedStageReadsRejectOversizedFilesBeforeAllocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 2 * 1_048_576)
        try handle.close()
        let directory = try MacTransactionDirectory(url: root)
        let retained = try MacRetainedFileObject(
            directory: directory,
            name: url.lastPathComponent
        )

        XCTAssertThrowsError(
            try retained.readData(maximumLength: 1_048_576)
        )
    }

    func testSystemCallerInspectorBindsLiveProcessAndSignedBundle() throws {
        let fixture = try SignedRunningApplicationFixture()
        defer { fixture.remove() }
        let process = try fixture.start()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let evidence = try SystemMacCallerInstallEvidenceInspector().inspect(
            processIdentifier: Int64(process.processIdentifier),
            targetURL: fixture.bundleURL,
            executableRelativePath: "Contents/MacOS/Example",
            applicationRequirement: "identifier com.example.app"
        )

        XCTAssertEqual(
            evidence.processIdentifier,
            Int64(process.processIdentifier)
        )
        XCTAssertTrue(evidence.processStartIdentity.hasPrefix("macos:"))
        XCTAssertEqual(evidence.executableSHA256.count, 64)
        XCTAssertEqual(evidence.packageID, "com.example.app")
        XCTAssertEqual(
            evidence.signerIdentity,
            #"identifier "com.example.app""#
        )
        XCTAssertEqual(
            evidence.targetURL.standardizedFileURL.path,
            fixture.bundleURL.standardizedFileURL.path
        )
        XCTAssertEqual(evidence.currentVersion, "2.7.0")
        XCTAssertEqual(evidence.currentBuildNumber, 270)
        XCTAssertEqual(evidence.currentPackageIdentitySHA256.count, 64)
        XCTAssertEqual(
            evidence.targetIdentityProofSHA256,
            evidence.executableSHA256
        )
    }

    func testAuthorizerBindsPolicyCallerStageAndTransactionInputs() throws {
        let fixture = try MacTransactionFixture(externalStage: true)
        defer { fixture.remove() }
        let policy = testPolicy(installRoot: fixture.rootURL.path)
        let request = try authorizationRequest(
            targetURL: fixture.targetURL,
            stageURL: fixture.stageURL,
            policy: policy
        )
        let process = RecordingMacCallerEvidenceInspector(
            evidence: MacCallerInstallEvidence(
                processIdentifier: request.caller.processIdentifier,
                processStartIdentity: request.caller.processStartIdentity,
                executableSHA256: request.caller.executableSHA256,
                signerIdentity: request.caller.signerIdentity,
                packageID: request.packageID,
                targetURL: fixture.targetURL,
                currentVersion: request.currentIdentity.version,
                currentBuildNumber: request.currentIdentity.buildNumber,
                currentPackageIdentitySHA256:
                    request.currentIdentity.packageIdentitySHA256,
                targetIdentityProofSHA256:
                    request.target.identityProofSHA256
            )
        )
        let stage = RecordingMacStageEvidenceInspector(
            evidence: MacStageInstallEvidence(
                stageURL: fixture.stageURL,
                payloadIdentity: fixture.verifier.identity(forVersion: "new"),
                verifier: fixture.verifier
            )
        )
        let validator = MacOneShotInstallRequestValidator(
            parentProcessIdentifier: {
                Int32(request.caller.processIdentifier)
            },
            callerInspector: process,
            stageInspector: stage
        )
        let authorizer = SealedMacOneShotInstallAuthorizer(
            policy: policy,
            helperEndpointIdentitySHA256: String(repeating: "f", count: 64),
            requestValidator: validator
        )

        let transaction = try authorizer.authorize(request)
        _ = try transaction.prepare()

        XCTAssertEqual(process.inspectedProcessIdentifier, 4_243)
        XCTAssertEqual(stage.inspectedStageURL, fixture.stageURL)
        XCTAssertEqual(try fixture.version(at: fixture.targetURL), "old")
        XCTAssertEqual(try fixture.version(at: fixture.stageURL), "new")
        XCTAssertEqual(
            try fixture.transactionArtifacts(),
            [
                ".Example.app.desktop-updater-"
                    + "00000000-0000-4000-8000-000000000006"
                    + ".journal.json",
                ".Example.app.desktop-updater-"
                    + "00000000-0000-4000-8000-000000000006"
                    + ".prepared",
                ".Example.app.desktop-updater-lock",
            ]
        )
    }

    func testValidatorAcceptsActualDesignatedRequirementThatSatisfiedPolicy()
        throws
    {
        let fixture = try MacTransactionFixture(externalStage: true)
        defer { fixture.remove() }
        let policy = testPolicy(installRoot: fixture.rootURL.path)
        let actualRequirement =
            "identifier com.example.app and anchor apple generic"
        let request = try authorizationRequest(
            targetURL: fixture.targetURL,
            stageURL: fixture.stageURL,
            policy: policy,
            callerSignerIdentity: actualRequirement
        )
        let caller = RecordingMacCallerEvidenceInspector(
            evidence: MacCallerInstallEvidence(
                processIdentifier: request.caller.processIdentifier,
                processStartIdentity: request.caller.processStartIdentity,
                executableSHA256: request.caller.executableSHA256,
                signerIdentity: actualRequirement,
                packageID: request.packageID,
                targetURL: fixture.targetURL,
                currentVersion: request.currentIdentity.version,
                currentBuildNumber: request.currentIdentity.buildNumber,
                currentPackageIdentitySHA256:
                    request.currentIdentity.packageIdentitySHA256,
                targetIdentityProofSHA256:
                    request.target.identityProofSHA256
            )
        )
        let validator = MacOneShotInstallRequestValidator(
            parentProcessIdentifier: {
                Int32(request.caller.processIdentifier)
            },
            callerInspector: caller,
            stageInspector: RecordingMacStageEvidenceInspector(
                evidence: MacStageInstallEvidence(
                    stageURL: fixture.stageURL,
                    payloadIdentity:
                        fixture.verifier.identity(forVersion: "new"),
                    verifier: fixture.verifier
                )
            )
        )

        _ = try validator.validate(request, policy: policy)
    }

    func testValidatorAcceptsSealedMacOSInstallerStrategy() throws {
        let fixture = try MacTransactionFixture(externalStage: true)
        defer { fixture.remove() }
        let policy = testPolicy(
            installRoot: fixture.rootURL.path,
            includeInstallerStrategy: true
        )
        let directoryRequest = try authorizationRequest(
            targetURL: fixture.targetURL,
            stageURL: fixture.stageURL,
            policy: policy
        )
        let request = NativeInstallTransactionRequestV1(
            schemaVersion: directoryRequest.schemaVersion,
            protocolVersion: directoryRequest.protocolVersion,
            transactionID: directoryRequest.transactionID,
            policyID: directoryRequest.policyID,
            packageID: directoryRequest.packageID,
            strategy: "verifiedInstallerHandoff",
            provider: "macosInstaller",
            target: directoryRequest.target,
            currentIdentity: directoryRequest.currentIdentity,
            desiredIdentity: directoryRequest.desiredIdentity,
            stage: directoryRequest.stage,
            signedDescriptor: directoryRequest.signedDescriptor,
            caller: directoryRequest.caller,
            requestNonce: directoryRequest.requestNonce,
            diagnosticsDestination:
                directoryRequest.diagnosticsDestination
        )
        let validator = MacOneShotInstallRequestValidator(
            parentProcessIdentifier: {
                Int32(request.caller.processIdentifier)
            },
            callerInspector: RecordingMacCallerEvidenceInspector(
                evidence: MacCallerInstallEvidence(
                    processIdentifier: request.caller.processIdentifier,
                    processStartIdentity:
                        request.caller.processStartIdentity,
                    executableSHA256: request.caller.executableSHA256,
                    signerIdentity: request.caller.signerIdentity,
                    packageID: request.packageID,
                    targetURL: fixture.targetURL,
                    currentVersion: request.currentIdentity.version,
                    currentBuildNumber:
                        request.currentIdentity.buildNumber,
                    currentPackageIdentitySHA256:
                        request.currentIdentity.packageIdentitySHA256,
                    targetIdentityProofSHA256:
                        request.target.identityProofSHA256
                )
            ),
            stageInspector: RecordingMacStageEvidenceInspector(
                evidence: MacStageInstallEvidence(
                    stageURL: fixture.stageURL,
                    installerExpectation:
                        MacVerifiedInstallerExpectation(
                            installerURL: fixture.stageURL
                                .appendingPathComponent("installer.pkg"),
                            kind: .pkg,
                            targetURL: fixture.targetURL,
                            packageIdentifier: request.packageID,
                            expectedVersion:
                                request.desiredIdentity.version,
                            expectedBuildNumber:
                                request.desiredIdentity.buildNumber,
                            designatedRequirement:
                                policy.allowedApplicationSigner.value,
                            artifactSHA256:
                                request.stage.artifactSHA256,
                            artifactLength:
                                request.stage.artifactLength,
                            expectedPackageIdentifiers: [
                                "com.example.app.pkg",
                            ],
                            descriptorSHA256:
                                request.signedDescriptor.canonicalSHA256,
                            provenanceSHA256:
                                request.stage.provenanceSHA256
                        ),
                    handoff: MacVerifiedInstallerHandoff(
                        verifier: AuthorizationInstallerChecker(),
                        runner: AuthorizationInstallerRunner()
                    )
                )
            )
        )

        _ = try validator.validate(request, policy: policy)
    }

    func testRejectsParentPidOrAnyCallerEvidenceMismatchBeforeLock() throws {
        let fixture = try MacTransactionFixture(externalStage: true)
        defer { fixture.remove() }
        let policy = testPolicy(installRoot: fixture.rootURL.path)
        let request = try authorizationRequest(
            targetURL: fixture.targetURL,
            stageURL: fixture.stageURL,
            policy: policy
        )
        let evidence = MacCallerInstallEvidence(
            processIdentifier: request.caller.processIdentifier,
            processStartIdentity: "attacker-start",
            executableSHA256: request.caller.executableSHA256,
            signerIdentity: request.caller.signerIdentity,
            packageID: request.packageID,
            targetURL: fixture.targetURL,
            currentVersion: request.currentIdentity.version,
            currentBuildNumber: request.currentIdentity.buildNumber,
            currentPackageIdentitySHA256:
                request.currentIdentity.packageIdentitySHA256,
            targetIdentityProofSHA256: request.target.identityProofSHA256
        )
        let validator = MacOneShotInstallRequestValidator(
            parentProcessIdentifier: { 4_244 },
            callerInspector: RecordingMacCallerEvidenceInspector(
                evidence: evidence
            ),
            stageInspector: RecordingMacStageEvidenceInspector(
                evidence: MacStageInstallEvidence(
                    stageURL: fixture.stageURL,
                    payloadIdentity:
                        fixture.verifier.identity(forVersion: "new"),
                    verifier: fixture.verifier
                )
            )
        )

        XCTAssertThrowsError(
            try validator.validate(request, policy: policy)
        ) { error in
            XCTAssertEqual(
                error as? MacOneShotAuthorizationError,
                .callerAuthenticationFailed
            )
        }
        XCTAssertEqual(try fixture.transactionArtifacts(), [])
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorBindsSignedDescriptorProvenanceAndBundle()
        throws
    {
        let fixture = try SignedStageFixture()
        defer { fixture.remove() }
        let policy = testPolicy(
            installRoot: fixture.installRootURL.path,
            releasePublicKey: fixture.publicKey
        )
        let request = try fixture.request(policy: policy)

        let evidence = try SystemMacStageInstallEvidenceInspector().inspect(
            request: request,
            policy: policy
        )

        XCTAssertEqual(evidence.stageURL.path, fixture.bundleURL.path)
        XCTAssertEqual(
            evidence.payloadIdentity.packageIdentifier,
            "com.example.app"
        )
        XCTAssertEqual(
            evidence.payloadIdentity.provenanceSHA256,
            fixture.markerSHA256
        )
        XCTAssertEqual(
            try evidence.verifier.verifyPayload(at: fixture.bundleURL),
            evidence.payloadIdentity
        )
        let copiedURL = fixture.rootURL.appendingPathComponent("Copied.app")
        try FileManager.default.copyItem(at: fixture.bundleURL, to: copiedURL)
        XCTAssertEqual(
            try evidence.verifier.verifyPayload(at: copiedURL),
            evidence.payloadIdentity
        )
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorRejectsInventoryMutation() throws {
        let fixture = try SignedStageFixture()
        defer { fixture.remove() }
        let policy = testPolicy(
            installRoot: fixture.installRootURL.path,
            releasePublicKey: fixture.publicKey
        )
        let request = try fixture.request(policy: policy)
        try Data("mutated archive".utf8).write(to: fixture.artifactURL)

        XCTAssertThrowsError(
            try SystemMacStageInstallEvidenceInspector().inspect(
                request: request,
                policy: policy
            )
        ) { error in
            XCTAssertEqual(
                error as? MacOneShotAuthorizationError,
                .stageAuthenticationFailed
            )
        }
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorRequiresBundledPrivilegedHelper() throws {
        let fixture = try SignedStageFixture(includeHelper: false)
        defer { fixture.remove() }
        let policy = testPolicy(
            installRoot: fixture.installRootURL.path,
            releasePublicKey: fixture.publicKey
        )

        XCTAssertThrowsError(
            try SystemMacStageInstallEvidenceInspector().inspect(
                request: fixture.request(policy: policy),
                policy: policy
            )
        )
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorRequiresExecutableMainAndHelper() throws {
        for (mainMode, helperMode) in [
            (mode_t(0o644), mode_t(0o755)),
            (mode_t(0o755), mode_t(0o644)),
            (mode_t(0o710), mode_t(0o755)),
            (mode_t(0o755), mode_t(0o710)),
        ] {
            let fixture = try SignedStageFixture(
                mainMode: mainMode,
                helperMode: helperMode
            )
            defer { fixture.remove() }
            let policy = testPolicy(
                installRoot: fixture.installRootURL.path,
                releasePublicKey: fixture.publicKey
            )

            XCTAssertThrowsError(
                try SystemMacStageInstallEvidenceInspector().inspect(
                    request: fixture.request(policy: policy),
                    policy: policy
                ),
                "main=\(String(mainMode, radix: 8)) "
                    + "helper=\(String(helperMode, radix: 8))"
            )
        }
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorRejectsInaccessibleBundleTree() throws {
        for (contentsMode, infoMode) in [
            (mode_t(0o700), mode_t(0o644)),
            (mode_t(0o755), mode_t(0o600)),
        ] {
            let fixture = try SignedStageFixture(
                contentsMode: contentsMode,
                infoMode: infoMode
            )
            defer { fixture.remove() }
            let policy = testPolicy(
                installRoot: fixture.installRootURL.path,
                releasePublicKey: fixture.publicKey
            )

            XCTAssertThrowsError(
                try SystemMacStageInstallEvidenceInspector().inspect(
                    request: fixture.request(policy: policy),
                    policy: policy
                ),
                "contents=\(String(contentsMode, radix: 8)) "
                    + "info=\(String(infoMode, radix: 8))"
            )
        }
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorAuthenticatesSignedPKGProviderEvidence()
        throws
    {
        for launchMode in ["installerApp", "privilegedInstallerTool"] {
            let fixture = try SignedPKGStageFixture(launchMode: launchMode)
            defer { fixture.remove() }
            let checker = AuthorizationInstallerChecker()
            let policy = testPolicy(
                installRoot: fixture.installRootURL.path,
                releasePublicKey: fixture.publicKey,
                includeInstallerStrategy: true
            )
            let request = try fixture.request(policy: policy)

            let evidence = try SystemMacStageInstallEvidenceInspector(
                installerVerifierFactory:
                    AuthorizationInstallerCheckerFactory(checker: checker)
            ).inspect(request: request, policy: policy)

            guard case let .verifiedInstaller(expectation, _) = evidence.payload
            else {
                return XCTFail("expected verified installer evidence")
            }
            XCTAssertEqual(evidence.stageURL, fixture.stageRootURL)
            XCTAssertEqual(expectation.installerURL, fixture.installerURL)
            XCTAssertEqual(expectation.targetURL.path, fixture.targetURL.path)
            XCTAssertEqual(
                expectation.expectedPackageIdentifiers,
                ["com.example.app.pkg"]
            )
            XCTAssertEqual(
                expectation.descriptorSHA256,
                fixture.descriptorSHA256
            )
            XCTAssertEqual(expectation.provenanceSHA256, fixture.markerSHA256)
            XCTAssertEqual(checker.verifiedInstallerCount, 1)
        }
    }

    @available(macOS 10.15, *)
    func testSystemStageInspectorRejectsPKGDescriptorWithoutBuildNumber()
        throws
    {
        let fixture = try SignedPKGStageFixture(buildNumber: nil)
        defer { fixture.remove() }
        let policy = testPolicy(
            installRoot: fixture.installRootURL.path,
            releasePublicKey: fixture.publicKey,
            includeInstallerStrategy: true
        )

        XCTAssertThrowsError(
            try SystemMacStageInstallEvidenceInspector(
                installerVerifierFactory:
                    AuthorizationInstallerCheckerFactory(
                        checker: AuthorizationInstallerChecker()
                    )
            ).inspect(
                request: fixture.request(policy: policy),
                policy: policy
            )
        )
    }
}

@available(macOS 10.15, *)
private final class SignedPKGStageFixture {
    let rootURL: URL
    let installRootURL: URL
    let targetURL: URL
    let stageRootURL: URL
    let installerURL: URL
    let publicKey: Data
    let descriptorSHA256: String
    let markerSHA256: String

    private let nonce = "22222222-2222-4222-8222-222222222222"
    private let artifactSHA256: String
    private let artifactLength: Int64
    private let signatureBase64: String
    private let desiredBuildNumber: Int64

    init(
        launchMode: String = "privilegedInstallerTool",
        buildNumber: Int64? = 290
    ) throws {
        desiredBuildNumber = buildNumber ?? 0
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        installRootURL = rootURL.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        targetURL = installRootURL.appendingPathComponent("Example.app")
        stageRootURL = rootURL.appendingPathComponent(
            "desktop_updater_stage_\(nonce)",
            isDirectory: true
        )
        installerURL = stageRootURL.appendingPathComponent("installer.pkg")
        try FileManager.default.createDirectory(
            at: targetURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stageRootURL,
            withIntermediateDirectories: true
        )
        let artifact = Data("signed package bytes".utf8)
        try artifact.write(to: installerURL)
        artifactSHA256 = testSHA256(artifact)
        artifactLength = Int64(artifact.count)

        let key = Curve25519.Signing.PrivateKey()
        publicKey = key.publicKey.rawRepresentation
        var descriptor: [String: Any] = [
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "appName": "Example.app",
            "version": "2.9.0",
            "platform": "macos",
            "channel": "stable",
            "artifact": [
                "kind": "pkgInstaller",
                "url": "https://updates.example.test/Example.pkg",
                "sha256": artifactSHA256,
                "length": artifactLength,
            ],
            "install": [
                "strategy": "pkgInstaller",
                "macosPkg": [
                    "launchMode": launchMode,
                    "expectedPackageIds": ["com.example.app.pkg"],
                    "relaunchAfterInstall": false,
                ],
            ],
            "minimumUpdaterVersion": "2.0.0",
            "generatedAt": "2026-07-16T00:00:00.000Z",
            "signature": [
                "algorithm": "ed25519",
                "publicKeyId": "stable-2026",
                "value": "",
            ],
        ]
        if let buildNumber {
            descriptor["buildNumber"] = buildNumber
        }
        let signature = try key.signature(for: testCanonicalJSON(descriptor))
        signatureBase64 = signature.base64EncodedString()
        descriptor["signature"] = [
            "algorithm": "ed25519",
            "publicKeyId": "stable-2026",
            "value": signatureBase64,
        ]
        let canonicalDescriptor = try testCanonicalJSON(descriptor)
        descriptorSHA256 = testSHA256(canonicalDescriptor)
        try JSONSerialization.data(
            withJSONObject: descriptor,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ).write(
            to: stageRootURL.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            )
        )
        let marker: [String: Any] = [
            "schemaVersion": 1,
            "nonce": nonce,
            "packageId": "com.example.app",
            "descriptorSha256": descriptorSHA256,
            "artifactSha256": artifactSHA256,
            "entries": try stageInventory(at: stageRootURL),
        ]
        let markerData = try testCanonicalJSON(marker)
        markerSHA256 = testSHA256(markerData)
        try markerData.write(
            to: stageRootURL.appendingPathComponent(
                ".desktop_updater_stage_provenance.json"
            )
        )
    }

    func request(policy: MacSealedInstallPolicyV1) throws
        -> NativeInstallTransactionRequestV1
    {
        let base = try authorizationRequest(
            targetURL: targetURL,
            stageURL: stageRootURL,
            policy: policy
        )
        return NativeInstallTransactionRequestV1(
            schemaVersion: base.schemaVersion,
            protocolVersion: base.protocolVersion,
            transactionID: base.transactionID,
            policyID: base.policyID,
            packageID: base.packageID,
            strategy: "verifiedInstallerHandoff",
            provider: "macosInstaller",
            target: base.target,
            currentIdentity: base.currentIdentity,
            desiredIdentity: NativeInstallVersionIdentityV1(
                version: "2.9.0",
                buildNumber: desiredBuildNumber,
                packageIdentitySHA256: descriptorSHA256
            ),
            stage: NativeInstallStageV1(
                pathHint: stageRootURL.path,
                ownershipNonce: testSHA256(Data(nonce.utf8)),
                provenanceSHA256: markerSHA256,
                artifactSHA256: artifactSHA256,
                artifactLength: artifactLength
            ),
            signedDescriptor: NativeInstallSignedDescriptorV1(
                canonicalSHA256: descriptorSHA256,
                signatureAlgorithm: "ed25519",
                keyID: "stable-2026",
                signatureBase64: signatureBase64
            ),
            caller: base.caller,
            requestNonce: base.requestNonce,
            diagnosticsDestination: base.diagnosticsDestination
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@available(macOS 10.15, *)
private final class SignedStageFixture {
    let rootURL: URL
    let installRootURL: URL
    let stageRootURL: URL
    let bundleURL: URL
    let artifactURL: URL
    let publicKey: Data
    let markerSHA256: String

    private let nonce = "11111111-1111-4111-8111-111111111111"
    private let artifactSHA256: String
    private let artifactLength: Int64
    private let descriptorSHA256: String
    private let signatureBase64: String
    private let executableSHA256: String

    init(
        includeHelper: Bool = true,
        mainMode: mode_t = 0o755,
        helperMode: mode_t = 0o755,
        contentsMode: mode_t = 0o755,
        infoMode: mode_t = 0o644
    ) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        installRootURL = rootURL.appendingPathComponent(
            "Applications",
            isDirectory: true
        )
        stageRootURL = rootURL.appendingPathComponent(
            "desktop_updater_stage_\(nonce)",
            isDirectory: true
        )
        bundleURL = stageRootURL.appendingPathComponent("Example.app")
        artifactURL = stageRootURL.appendingPathComponent(
            ".desktop_updater_artifact.zip"
        )
        try FileManager.default.createDirectory(
            at: installRootURL,
            withIntermediateDirectories: true
        )
        let executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/Example"
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: executableURL
        )
        XCTAssertEqual(Darwin.chmod(executableURL.path, mainMode), 0)
        if includeHelper {
            let helperURL = bundleURL.appendingPathComponent(
                "Contents/Helpers/DesktopUpdaterInstallHelper"
            )
            try FileManager.default.createDirectory(
                at: helperURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"),
                to: helperURL
            )
            XCTAssertEqual(Darwin.chmod(helperURL.path, helperMode), 0)
        }
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.8.0",
                "CFBundleVersion": "280",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        try info.write(to: infoURL)
        try signBundle(bundleURL)
        XCTAssertEqual(Darwin.chmod(infoURL.path, infoMode), 0)
        XCTAssertEqual(
            Darwin.chmod(
                bundleURL.appendingPathComponent("Contents").path,
                contentsMode
            ),
            0
        )
        executableSHA256 = testSHA256(try Data(contentsOf: executableURL))

        let artifact = Data("verified zip archive".utf8)
        try artifact.write(to: artifactURL)
        artifactSHA256 = testSHA256(artifact)
        artifactLength = Int64(artifact.count)

        let key = Curve25519.Signing.PrivateKey()
        publicKey = key.publicKey.rawRepresentation
        var descriptor = Self.descriptor(
            artifactSHA256: artifactSHA256,
            artifactLength: artifactLength,
            signature: ""
        )
        let signature = try key.signature(
            for: testCanonicalJSON(descriptor)
        )
        signatureBase64 = signature.base64EncodedString()
        descriptor["signature"] = [
            "algorithm": "ed25519",
            "publicKeyId": "stable-2026",
            "value": signatureBase64,
        ]
        let canonicalDescriptor = try testCanonicalJSON(descriptor)
        descriptorSHA256 = testSHA256(canonicalDescriptor)
        try JSONSerialization.data(
            withJSONObject: descriptor,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ).write(
            to: stageRootURL.appendingPathComponent(
                ".desktop_updater_release_manifest.json"
            )
        )

        let entries = try stageInventory(at: stageRootURL)
        let marker: [String: Any] = [
            "schemaVersion": 1,
            "nonce": nonce,
            "packageId": "com.example.app",
            "descriptorSha256": descriptorSHA256,
            "artifactSha256": artifactSHA256,
            "entries": entries,
        ]
        let markerData = try testCanonicalJSON(marker)
        markerSHA256 = testSHA256(markerData)
        try markerData.write(
            to: stageRootURL.appendingPathComponent(
                ".desktop_updater_stage_provenance.json"
            )
        )
    }

    func request(
        policy: MacSealedInstallPolicyV1
    ) throws -> NativeInstallTransactionRequestV1 {
        let base = try authorizationRequest(
            targetURL: installRootURL.appendingPathComponent("Example.app"),
            stageURL: bundleURL,
            policy: policy
        )
        return NativeInstallTransactionRequestV1(
            schemaVersion: base.schemaVersion,
            protocolVersion: base.protocolVersion,
            transactionID: base.transactionID,
            policyID: base.policyID,
            packageID: base.packageID,
            strategy: base.strategy,
            provider: base.provider,
            target: base.target,
            currentIdentity: base.currentIdentity,
            desiredIdentity: NativeInstallVersionIdentityV1(
                version: "2.8.0",
                buildNumber: 280,
                packageIdentitySHA256: descriptorSHA256
            ),
            stage: NativeInstallStageV1(
                pathHint: bundleURL.path,
                ownershipNonce: testSHA256(Data(nonce.utf8)),
                provenanceSHA256: markerSHA256,
                artifactSHA256: artifactSHA256,
                artifactLength: artifactLength
            ),
            signedDescriptor: NativeInstallSignedDescriptorV1(
                canonicalSHA256: descriptorSHA256,
                signatureAlgorithm: "ed25519",
                keyID: "stable-2026",
                signatureBase64: signatureBase64
            ),
            caller: base.caller,
            requestNonce: base.requestNonce,
            diagnosticsDestination: base.diagnosticsDestination
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func descriptor(
        artifactSHA256: String,
        artifactLength: Int64,
        signature: String
    ) -> [String: Any] {
        [
            "schemaVersion": 3,
            "packageId": "com.example.app",
            "appName": "Example.app",
            "version": "2.8.0",
            "buildNumber": 280,
            "platform": "macos",
            "channel": "stable",
            "artifact": [
                "kind": "zip",
                "url": "https://updates.example.test/Example.zip",
                "sha256": artifactSHA256,
                "length": artifactLength,
            ],
            "install": ["strategy": "wholeBundleReplace"],
            "minimumUpdaterVersion": "2.0.0",
            "generatedAt": "2026-07-14T00:00:00.000Z",
            "signature": [
                "algorithm": "ed25519",
                "publicKeyId": "stable-2026",
                "value": signature,
            ],
        ]
    }
}

private final class SignedRunningApplicationFixture {
    let rootURL: URL
    let bundleURL: URL
    private let executableURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        bundleURL = rootURL.appendingPathComponent("Example.app")
        executableURL = bundleURL.appendingPathComponent(
            "Contents/MacOS/Example"
        )
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: executableURL
        )
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.app",
                "CFBundleExecutable": "Example",
                "CFBundleShortVersionString": "2.7.0",
                "CFBundleVersion": "270",
                "CFBundlePackageType": "APPL",
            ],
            format: .xml,
            options: 0
        )
        try info.write(
            to: bundleURL.appendingPathComponent("Contents/Info.plist")
        )
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = [
            "--force", "--deep", "--sign", "-", "--identifier",
            "com.example.app",
            "-r=designated => identifier com.example.app",
            bundleURL.path,
        ]
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func start() throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["5"]
        try process.run()
        let deadline = Date().addingTimeInterval(2)
        var pathBuffer = [CChar](
            repeating: 0,
            count: Int(MAXPATHLEN) * 4
        )
        repeat {
            if proc_pidpath(
                process.processIdentifier,
                &pathBuffer,
                UInt32(pathBuffer.count)
            ) > 0 {
                return process
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while process.isRunning && Date() < deadline
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        throw CocoaError(.executableNotLoadable)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class RecordingMacCallerEvidenceInspector:
    MacCallerInstallEvidenceInspecting
{
    let evidence: MacCallerInstallEvidence
    private(set) var inspectedProcessIdentifier: Int64?

    init(evidence: MacCallerInstallEvidence) {
        self.evidence = evidence
    }

    func inspect(
        processIdentifier: Int64,
        targetURL _: URL,
        executableRelativePath _: String,
        applicationRequirement _: String
    ) throws -> MacCallerInstallEvidence {
        inspectedProcessIdentifier = processIdentifier
        return evidence
    }
}

private final class RecordingMacStageEvidenceInspector:
    MacStageInstallEvidenceInspecting
{
    let evidence: MacStageInstallEvidence
    private(set) var inspectedStageURL: URL?

    init(evidence: MacStageInstallEvidence) {
        self.evidence = evidence
    }

    func inspect(
        request: NativeInstallTransactionRequestV1,
        policy _: MacSealedInstallPolicyV1
    ) throws -> MacStageInstallEvidence {
        inspectedStageURL = URL(fileURLWithPath: request.stage.pathHint)
            .standardizedFileURL
        return evidence
    }
}

private final class AuthorizationInstallerChecker:
    MacVerifiedInstallerChecking
{
    private(set) var verifiedInstallerCount = 0

    func verifyInstaller(
        _ expectation: MacVerifiedInstallerExpectation
    ) throws -> MacVerifiedInstallerSecurityEvidence {
        verifiedInstallerCount += 1
        return MacVerifiedInstallerSecurityEvidence(
            receiptVersions: Dictionary(
                uniqueKeysWithValues:
                    expectation.expectedPackageIdentifiers.map {
                        ($0, expectation.expectedVersion)
                    }
            ),
            executableSHA256: String(repeating: "e", count: 64),
            bundleTreeSHA256: String(repeating: "f", count: 64)
        )
    }

    func verifyInstalledPackage(identifier _: String, version _: String)
        throws {}
}

private final class AuthorizationInstallerCheckerFactory:
    MacVerifiedInstallerCheckingCreating
{
    let checker: AuthorizationInstallerChecker

    init(checker: AuthorizationInstallerChecker) {
        self.checker = checker
    }

    func makeVerifier(
        expectation _: MacVerifiedInstallerExpectation
    ) throws -> any MacVerifiedInstallerChecking {
        checker
    }
}

private final class AuthorizationInstallerRunner: MacFixedInstallerRunning {
    func spawnVerifiedInstaller(
        at _: URL,
        kind _: MacVerifiedInstallerKind
    ) throws -> any MacGatedInstallerWorker {
        AuthorizationInstallerWorker()
    }
}

private final class AuthorizationInstallerWorker: MacGatedInstallerWorker {
    let identity = MacInstallerWorkerIdentity(
        processIdentifier: 999_999,
        processStartIdentity: "macos:1:1",
        providerTransactionIdentity: "provider"
    )

    func releaseAndWait() throws {}
}

private func signBundle(_ bundleURL: URL) throws {
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = [
        "--force", "--deep", "--sign", "-", "--identifier",
        "com.example.app",
        "-r=designated => identifier com.example.app",
        bundleURL.path,
    ]
    try sign.run()
    sign.waitUntilExit()
    guard sign.terminationStatus == 0 else {
        throw CocoaError(.fileWriteUnknown)
    }
}

private func testCanonicalJSON(_ object: Any) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
}

private func testSHA256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func stageInventory(at rootURL: URL) throws -> [[String: Any]] {
    let canonicalRoot = try testRealURL(rootURL)
    guard let enumerator = FileManager.default.enumerator(
        at: canonicalRoot,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ],
        options: []
    ) else {
        throw CocoaError(.fileReadUnknown)
    }
    var entries: [[String: Any]] = []
    for case let url as URL in enumerator {
        let relative = String(
            url.path.dropFirst(canonicalRoot.path.count + 1)
        )
        if relative == ".desktop_updater_stage_provenance.json" {
            continue
        }
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        if values.isSymbolicLink == true {
            entries.append([
                "path": relative,
                "kind": "symlink",
                "length": 0,
                "target": try FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path
                ),
            ])
        } else if values.isDirectory == true {
            entries.append([
                "path": relative,
                "kind": "directory",
                "length": 0,
            ])
        } else if values.isRegularFile == true {
            let data = try Data(contentsOf: url)
            entries.append([
                "path": relative,
                "kind": "file",
                "length": data.count,
                "sha256": testSHA256(data),
            ])
        } else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
    return entries.sorted {
        let left = ($0["path"] as? String ?? "").utf8
        let right = ($1["path"] as? String ?? "").utf8
        return left.lexicographicallyPrecedes(right)
    }
}

private func testRealURL(_ url: URL) throws -> URL {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard url.path.withCString({ realpath($0, &buffer) }) != nil else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    return URL(fileURLWithPath: String(cString: buffer))
}

private func testPolicy(
    installRoot: String,
    releasePublicKey: Data = Data(repeating: 1, count: 32),
    includeInstallerStrategy: Bool = false
) -> MacSealedInstallPolicyV1 {
    var strategies: Set<MacSealedInstallStrategy> = [
        MacSealedInstallStrategy(
            strategy: "directoryReplace",
            provider: "platformDirectory"
        ),
    ]
    if includeInstallerStrategy {
        strategies.insert(
            MacSealedInstallStrategy(
                strategy: "verifiedInstallerHandoff",
                provider: "macosInstaller"
            )
        )
    }
    return MacSealedInstallPolicyV1(
        policyVersion: 1,
        policyID: "com.example.desktop-updater.test",
        applicationPackageID: "com.example.app",
        helperServiceID: "com.example.desktop-updater.helper",
        allowedApplicationSigner: MacSealedPolicySigner(
            kind: "appleDesignatedRequirement",
            value: "identifier com.example.app"
        ),
        allowedHelperSigner: MacSealedPolicySigner(
            kind: "appleDesignatedRequirement",
            value: "identifier com.example.desktop-updater.helper"
        ),
        allowedTargetClasses: ["applicationBundle"],
        allowedInstallRoots: [installRoot],
        releaseRootPublicKeys: [
            MacSealedReleaseRootKey(
                keyID: "stable-2026",
                algorithm: "ed25519",
                publicKey: releasePublicKey
            ),
        ],
        allowedStrategies: strategies,
        minimumHelperProtocolVersion: 1,
        canonicalSHA256: String(repeating: "e", count: 64)
    )
}

private func authorizationRequest(
    targetURL: URL,
    stageURL: URL,
    policy: MacSealedInstallPolicyV1,
    callerSignerIdentity: String? = nil
) throws -> NativeInstallTransactionRequestV1 {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        let file = candidate.appendingPathComponent(
            "fixtures/compat/native-install-helper/v1/valid-requests.json"
        )
        if FileManager.default.fileExists(atPath: file.path) {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: file))
                    as? [String: Any]
            )
            let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
            var request = try XCTUnwrap(
                try XCTUnwrap(cases.first)["request"] as? [String: Any]
            )
            request["transactionId"] =
                "00000000-0000-4000-8000-000000000006"
            request["policyId"] = policy.policyID
            request["target"] = [
                "class": "applicationBundle",
                "pathHint": targetURL.path,
                "targetNameHint": targetURL.lastPathComponent,
                "executableRelativePath": "Contents/MacOS/Example",
                "identityProofSha256": String(repeating: "a", count: 64),
            ]
            var caller = try XCTUnwrap(
                request["caller"] as? [String: Any]
            )
            caller["signerIdentity"] = callerSignerIdentity
                ?? policy.allowedApplicationSigner.value
            request["caller"] = caller
            var stage = try XCTUnwrap(request["stage"] as? [String: Any])
            stage["pathHint"] = stageURL.path
            stage["provenanceSha256"] = String(repeating: "a", count: 64)
            request["stage"] = stage
            return try NativeInstallTransactionRequestV1.parse(
                JSONSerialization.data(
                    withJSONObject: request,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )
            )
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
