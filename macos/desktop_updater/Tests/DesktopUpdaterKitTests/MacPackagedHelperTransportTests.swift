import Foundation
import XCTest
@testable import DesktopUpdaterKit

final class MacPackagedHelperTransportTests: XCTestCase {
    func testSystemAuthenticatorBindsTheRunningFixedSignedHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("DesktopUpdaterInstallHelper")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/sleep"),
            to: helper
        )
        let requirement =
            "identifier \"com.example.desktop-updater.helper\""
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = [
            "--force", "--sign", "-", "--identifier",
            "com.example.desktop-updater.helper",
            "-r=designated => \(requirement)", helper.path,
        ]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let authenticator = SystemMacOneShotEndpointAuthenticator(
            infoDictionary: [
                "DesktopUpdaterInstallHelperServiceID":
                    "com.example.desktop-updater.helper",
                "DesktopUpdaterInstallHelperRequirement": requirement,
            ]
        )

        let staticIdentity = try authenticator.authenticate(
            executableURL: helper,
            processIdentifier: nil
        )
        let runningIdentity = try authenticator.authenticate(
            executableURL: helper,
            processIdentifier: process.processIdentifier
        )

        XCTAssertEqual(runningIdentity, staticIdentity)
        XCTAssertEqual(runningIdentity.count, 64)
    }

    func testSystemInstallerRegistersModernBundledLaunchDaemon() throws {
        let fixture = try ModernLaunchDaemonFixture()
        defer { fixture.remove() }
        let registrar = RecordingMacPrivilegedServiceRegistrar(
            statuses: [.notRegistered, .enabled]
        )
        let authenticator = RecordingEndpointAuthenticator()
        let installer = SystemMacPrivilegedHelperInstaller(
            applicationBundleURL: fixture.applicationURL,
            oneShotHelperURL: fixture.helperURL,
            infoDictionary: fixture.infoDictionary,
            authenticator: authenticator,
            registrar: registrar
        )

        try installer.install()

        XCTAssertEqual(
            registrar.statusPlistNames,
            [fixture.plistName, fixture.plistName]
        )
        XCTAssertEqual(registrar.registeredPlistNames, [fixture.plistName])
        XCTAssertEqual(authenticator.processIdentifiers.count, 1)
        XCTAssertNil(authenticator.processIdentifiers[0])
    }

    func testSystemInstallerRegistersWhenInitialStatusIsNotFound() throws {
        let fixture = try ModernLaunchDaemonFixture()
        defer { fixture.remove() }
        let registrar = RecordingMacPrivilegedServiceRegistrar(
            statuses: [.notFound, .enabled]
        )
        let installer = SystemMacPrivilegedHelperInstaller(
            applicationBundleURL: fixture.applicationURL,
            oneShotHelperURL: fixture.helperURL,
            infoDictionary: fixture.infoDictionary,
            authenticator: RecordingEndpointAuthenticator(),
            registrar: registrar
        )

        try installer.install()

        XCTAssertEqual(registrar.registeredPlistNames, [fixture.plistName])
    }

    func testSystemInstallerRefreshesEnabledDaemonRegistration() throws {
        let fixture = try ModernLaunchDaemonFixture()
        defer { fixture.remove() }
        let registrar = RecordingMacPrivilegedServiceRegistrar(
            statuses: [.enabled, .enabled]
        )
        let installer = SystemMacPrivilegedHelperInstaller(
            applicationBundleURL: fixture.applicationURL,
            oneShotHelperURL: fixture.helperURL,
            infoDictionary: fixture.infoDictionary,
            authenticator: RecordingEndpointAuthenticator(),
            registrar: registrar
        )

        try installer.install()

        XCTAssertEqual(registrar.unregisteredPlistNames, [fixture.plistName])
        XCTAssertEqual(registrar.registeredPlistNames, [fixture.plistName])
        XCTAssertEqual(
            registrar.statusPlistNames,
            [fixture.plistName, fixture.plistName]
        )
    }

    func testAppServiceUnregistrationWaitsForCompletion() throws {
        let waiter = MacAppServiceUnregistrationWaiter()
        let startedAt = DispatchTime.now().uptimeNanoseconds

        try waiter.wait(timeout: .now() + 1) { completion in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .milliseconds(25)
            ) {
                completion(nil)
            }
        }

        let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
        XCTAssertGreaterThanOrEqual(elapsed, 20_000_000)
    }

    func testSystemInstallerReportsWhenAdminApprovalIsRequired()
        throws
    {
        let fixture = try ModernLaunchDaemonFixture()
        defer { fixture.remove() }
        let registrar = RecordingMacPrivilegedServiceRegistrar(
            statuses: [.requiresApproval]
        )
        let installer = SystemMacPrivilegedHelperInstaller(
            applicationBundleURL: fixture.applicationURL,
            oneShotHelperURL: fixture.helperURL,
            infoDictionary: fixture.infoDictionary,
            authenticator: RecordingEndpointAuthenticator(),
            registrar: registrar
        )

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .privilegedHelperApprovalRequired
            )
        }
        XCTAssertTrue(registrar.registeredPlistNames.isEmpty)
    }

    func testSystemInstallerReportsApprovalRequiredAfterRegistration()
        throws
    {
        let fixture = try ModernLaunchDaemonFixture()
        defer { fixture.remove() }
        let registrar = RecordingMacPrivilegedServiceRegistrar(
            statuses: [.notRegistered, .requiresApproval]
        )
        let installer = SystemMacPrivilegedHelperInstaller(
            applicationBundleURL: fixture.applicationURL,
            oneShotHelperURL: fixture.helperURL,
            infoDictionary: fixture.infoDictionary,
            authenticator: RecordingEndpointAuthenticator(),
            registrar: registrar
        )

        XCTAssertThrowsError(try installer.install()) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .privilegedHelperApprovalRequired
            )
        }
        XCTAssertEqual(registrar.registeredPlistNames, [fixture.plistName])
    }

    func testPrepareAndCommitUseOneFixedFramedProcessSession() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let reservation = reservationData(transactionID: transactionID)
        let session = RecordingMacOneShotClientSession(
            responses: [reservation, reservation]
        )
        let launcher = RecordingMacOneShotProcessLauncher(session: session)
        let helper = URL(
            fileURLWithPath:
                "/Applications/Example.app/Contents/Helpers/"
                + "DesktopUpdaterInstallHelper"
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: helper,
            launcher: launcher,
            authenticator: RecordingEndpointAuthenticator()
        )

        let response = try transport.prepareInstall(
            request: Data("canonical-request".utf8),
            transactionID: transactionID
        )
        let status = try transport.commitAfterExit(
            transactionID: transactionID,
            readyToken: response.readyToken
        )

        XCTAssertEqual(launcher.executableURL, helper)
        XCTAssertEqual(launcher.arguments, ["--one-shot-service"])
        XCTAssertEqual(session.processIdentifier, 4_242)
        XCTAssertEqual(session.requests.first, Data("canonical-request".utf8))
        let command = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.requests[1])
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(command.keys),
            [
                "operation", "protocolVersion", "transactionId",
                "readyToken", "journalSha256",
                "helperEndpointIdentitySha256",
            ]
        )
        XCTAssertEqual(command["operation"] as? String, "commitAfterExit")
        XCTAssertEqual(
            command["journalSha256"] as? String,
            response.journalSHA256
        )
        XCTAssertEqual(status.state, .commitAccepted)
        XCTAssertEqual(status.resultCode, .accepted)
        XCTAssertTrue(session.didCloseInput)
    }

    func testCancellationRequiresCanonicalRollbackAcknowledgement() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [
                reservationData(transactionID: transactionID),
                recoveryData(transactionID: transactionID),
            ]
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            launcher: RecordingMacOneShotProcessLauncher(session: session),
            authenticator: RecordingEndpointAuthenticator()
        )
        let reservation = try transport.prepareInstall(
            request: Data("canonical-request".utf8),
            transactionID: transactionID
        )

        let status = try transport.cancelReservation(
            transactionID: transactionID,
            readyToken: reservation.readyToken
        )

        XCTAssertEqual(status.state, .cancelled)
        XCTAssertEqual(status.resultCode, .succeeded)
        XCTAssertTrue(session.didCloseInput)
    }

    func testRejectsReservationFromDifferentEndpointIdentity() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [reservationData(transactionID: transactionID)]
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            launcher: RecordingMacOneShotProcessLauncher(session: session),
            authenticator: RecordingEndpointAuthenticator(
                identity: String(repeating: "d", count: 64)
            )
        )

        XCTAssertThrowsError(
            try transport.prepareInstall(
                request: Data("canonical-request".utf8),
                transactionID: transactionID
            )
        ) { error in
            XCTAssertEqual(
                error as? MacInstallClientError,
                .invalidReservationResponse
            )
        }
        XCTAssertTrue(session.didCloseInput)
    }

    func testQueryUsesAuthenticatedPersistentRecoverySession() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [
                statusData(
                    transactionID: transactionID,
                    state: "prepared",
                    resultCode: "recoveryRequired"
                ),
            ]
        )
        let launcher = RecordingMacOneShotProcessLauncher(session: session)
        let authenticator = RecordingEndpointAuthenticator()
        let helper = URL(fileURLWithPath: "/fixed/helper")
        let transport = PackagedMacInstallHelperTransport(
            helperURL: helper,
            policyID: "com.example.desktop-updater.test",
            launcher: launcher,
            authenticator: authenticator
        )

        let status = try transport.queryTransaction(
            transactionID: transactionID
        )

        XCTAssertEqual(launcher.executableURL, helper)
        XCTAssertEqual(launcher.arguments, ["--one-shot-recovery"])
        XCTAssertEqual(authenticator.processIdentifiers.count, 2)
        XCTAssertNil(authenticator.processIdentifiers[0])
        XCTAssertEqual(authenticator.processIdentifiers[1], 4_242)
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.requests[0])
                as? [String: Any]
        )
        XCTAssertEqual(
            Set(request.keys),
            ["operation", "policyId", "protocolVersion", "transactionId"]
        )
        XCTAssertEqual(request["operation"] as? String, "queryTransaction")
        XCTAssertEqual(
            request["policyId"] as? String,
            "com.example.desktop-updater.test"
        )
        XCTAssertEqual(status.state, .prepared)
        XCTAssertEqual(status.resultCode, .recoveryRequired)
        XCTAssertEqual(
            status.helperEndpointIdentitySHA256,
            String(repeating: "c", count: 64)
        )
        XCTAssertTrue(session.didCloseInput)
    }

    func testQueryMapsDurableInstallerCommitAcceptedState() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [
                statusData(
                    transactionID: transactionID,
                    state: "commitAccepted",
                    resultCode: "recoveryRequired"
                ),
            ]
        )
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: RecordingMacOneShotProcessLauncher(session: session),
            authenticator: RecordingEndpointAuthenticator()
        )

        let status = try transport.queryTransaction(
            transactionID: transactionID
        )

        XCTAssertEqual(status.state, .commitAccepted)
        XCTAssertEqual(status.resultCode, .recoveryRequired)
    }

    func testRecoveryMapsVerifiedRollbackFromAuthenticatedHelper() throws {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let session = RecordingMacOneShotClientSession(
            responses: [recoveryData(transactionID: transactionID)]
        )
        let launcher = RecordingMacOneShotProcessLauncher(session: session)
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: launcher,
            authenticator: RecordingEndpointAuthenticator()
        )

        let status = try transport.recoverPendingInstall(
            transactionID: transactionID
        )

        XCTAssertEqual(launcher.arguments, ["--one-shot-recovery"])
        let request = try XCTUnwrap(
            JSONSerialization.jsonObject(with: session.requests[0])
                as? [String: Any]
        )
        XCTAssertEqual(
            request["operation"] as? String,
            "recoverPendingInstall"
        )
        XCTAssertEqual(status.state, .rolledBack)
        XCTAssertEqual(status.resultCode, .succeeded)
        XCTAssertEqual(status.detail, "oldTarget")
        XCTAssertEqual(
            status.responseDigestSHA256,
            String(repeating: "b", count: 64)
        )
        XCTAssertTrue(session.didCloseInput)
    }

    func testProtectedPrepareAndCommitUseInstalledAuthenticatedXPC()
        throws
    {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let oneShot = RecordingMacOneShotProcessLauncher(
            session: RecordingMacOneShotClientSession(responses: [])
        )
        let privileged = RecordingPrivilegedXPCExchange(
            responses: [
                reservationData(transactionID: transactionID),
                reservationData(transactionID: transactionID),
            ]
        )
        let installer = RecordingPrivilegedHelperInstaller {
            privileged.isInstalled = true
        }
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: oneShot,
            authenticator: RecordingEndpointAuthenticator(),
            privilegedInstaller: installer,
            privilegedExchange: privileged,
            privilegeRequired: { _ in true }
        )

        let reservation = try transport.prepareInstall(
            request: Data("canonical-request".utf8),
            transactionID: transactionID
        )
        let status = try transport.commitAfterExit(
            transactionID: transactionID,
            readyToken: reservation.readyToken
        )

        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(privileged.validationCount, 2)
        XCTAssertEqual(
            privileged.operations,
            ["prepareInstall", "commitAfterExit"]
        )
        XCTAssertEqual(oneShot.launchCount, 0)
        XCTAssertEqual(status.state, .commitAccepted)
        XCTAssertEqual(status.resultCode, .accepted)
    }

    func testRecoveryFallsBackToInstalledXPCAfterUnprivilegedFailure()
        throws
    {
        let transactionID = "00000000-0000-4000-8000-000000000099"
        let oneShot = RecordingMacOneShotProcessLauncher(
            session: RecordingMacOneShotClientSession(responses: [])
        )
        let privileged = RecordingPrivilegedXPCExchange(
            responses: [recoveryData(transactionID: transactionID)]
        )
        let installer = RecordingPrivilegedHelperInstaller {
            privileged.isInstalled = true
        }
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: oneShot,
            authenticator: RecordingEndpointAuthenticator(),
            privilegedInstaller: installer,
            privilegedExchange: privileged
        )

        let status = try transport.recoverPendingInstall(
            transactionID: transactionID
        )

        XCTAssertEqual(oneShot.launchCount, 1)
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(privileged.operations, ["recoverPendingInstall"])
        XCTAssertEqual(status.state, .rolledBack)
        XCTAssertEqual(status.resultCode, .succeeded)
    }

    func testForcedPersistentPrivilegeUsesInstalledXPCFromFreshTransport()
        throws
    {
        let queryTransactionID =
            "00000000-0000-4000-8000-000000000099"
        let recoveryTransactionID =
            "00000000-0000-4000-8000-000000000100"
        let oneShot = RecordingMacOneShotProcessLauncher(
            session: RecordingMacOneShotClientSession(responses: [])
        )
        let privileged = RecordingPrivilegedXPCExchange(
            responses: [
                statusData(
                    transactionID: queryTransactionID,
                    state: "prepared",
                    resultCode: "recoveryRequired"
                ),
                recoveryData(transactionID: recoveryTransactionID),
            ]
        )
        privileged.isInstalled = true
        let installer = RecordingPrivilegedHelperInstaller {}
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: oneShot,
            authenticator: RecordingEndpointAuthenticator(),
            privilegedInstaller: installer,
            privilegedExchange: privileged,
            forcePrivilegedPersistentOperations: true
        )

        let query = try transport.queryTransaction(
            transactionID: queryTransactionID
        )
        let recovery = try transport.recoverPendingInstall(
            transactionID: recoveryTransactionID
        )

        XCTAssertEqual(oneShot.launchCount, 0)
        XCTAssertEqual(installer.installCount, 0)
        XCTAssertEqual(
            privileged.operations,
            ["queryTransaction", "recoverPendingInstall"]
        )
        XCTAssertEqual(query.state, .prepared)
        XCTAssertEqual(query.resultCode, .recoveryRequired)
        XCTAssertEqual(recovery.state, .rolledBack)
        XCTAssertEqual(recovery.resultCode, .succeeded)
    }

    func testForcedPersistentQueryInstallsUnavailableXPCFromFreshTransport()
        throws
    {
        let transactionID =
            "00000000-0000-4000-8000-000000000099"
        let oneShot = RecordingMacOneShotProcessLauncher(
            session: RecordingMacOneShotClientSession(responses: [])
        )
        let privileged = RecordingPrivilegedXPCExchange(
            responses: [
                statusData(
                    transactionID: transactionID,
                    state: "prepared",
                    resultCode: "recoveryRequired"
                ),
            ]
        )
        let installer = RecordingPrivilegedHelperInstaller {
            privileged.isInstalled = true
        }
        let transport = PackagedMacInstallHelperTransport(
            helperURL: URL(fileURLWithPath: "/fixed/helper"),
            policyID: "com.example.desktop-updater.test",
            launcher: oneShot,
            authenticator: RecordingEndpointAuthenticator(),
            privilegedInstaller: installer,
            privilegedExchange: privileged,
            forcePrivilegedPersistentOperations: true
        )

        let query = try transport.queryTransaction(
            transactionID: transactionID
        )

        XCTAssertEqual(oneShot.launchCount, 0)
        XCTAssertEqual(installer.installCount, 1)
        XCTAssertEqual(privileged.operations, ["queryTransaction"])
        XCTAssertEqual(query.state, .prepared)
        XCTAssertEqual(query.resultCode, .recoveryRequired)
    }

    func testPrivilegeSelectionUsesTargetClassAndParentPermissions()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            try PackagedMacInstallHelperTransport.defaultPrivilegeRequired(
                targetRequestData(
                    targetClass: "protectedApplication",
                    path: root.appendingPathComponent("Example.app").path
                )
            )
        )
        XCTAssertFalse(
            try PackagedMacInstallHelperTransport.defaultPrivilegeRequired(
                targetRequestData(
                    targetClass: "applicationBundle",
                    path: root.appendingPathComponent("Example.app").path
                )
            )
        )
        XCTAssertTrue(
            try PackagedMacInstallHelperTransport.defaultPrivilegeRequired(
                targetRequestData(
                    targetClass: "applicationBundle",
                    path: root.appendingPathComponent("Example.app").path,
                    strategy: "verifiedInstallerHandoff",
                    provider: "macosInstaller"
                )
            )
        )
    }

    func testApplicationsRootUsesActualParentWriteAccess() {
        XCTAssertEqual(
            SystemMacInstallRequestEvidenceBuilder.targetClass(
                for: URL(fileURLWithPath: "/Applications/Example.app"),
                isWritableDirectory: { $0 == "/Applications" }
            ),
            "applicationBundle"
        )
        XCTAssertEqual(
            SystemMacInstallRequestEvidenceBuilder.targetClass(
                for: URL(fileURLWithPath: "/Applications/Example.app"),
                isWritableDirectory: { _ in false }
            ),
            "protectedApplication"
        )
        XCTAssertEqual(
            SystemMacInstallRequestEvidenceBuilder.targetClass(
                for: URL(fileURLWithPath: "/tmp/Example.app"),
                isWritableDirectory: { _ in false }
            ),
            "applicationBundle"
        )
    }
}

private final class RecordingPrivilegedHelperInstaller:
    MacPrivilegedHelperInstalling
{
    private let onInstall: () -> Void
    private(set) var installCount = 0

    init(onInstall: @escaping () -> Void) {
        self.onInstall = onInstall
    }

    func install() throws {
        installCount += 1
        onInstall()
    }
}

private final class RecordingMacPrivilegedServiceRegistrar:
    MacPrivilegedServiceRegistering
{
    private var statuses: [MacPrivilegedServiceRegistrationStatus]
    private(set) var statusPlistNames: [String] = []
    private(set) var registeredPlistNames: [String] = []
    private(set) var unregisteredPlistNames: [String] = []

    init(statuses: [MacPrivilegedServiceRegistrationStatus]) {
        self.statuses = statuses
    }

    func status(
        plistName: String
    ) throws -> MacPrivilegedServiceRegistrationStatus {
        statusPlistNames.append(plistName)
        guard !statuses.isEmpty else {
            throw MacInstallClientError.endpointUnavailable
        }
        return statuses.removeFirst()
    }

    func register(plistName: String) throws {
        registeredPlistNames.append(plistName)
    }

    func unregister(plistName: String) throws {
        unregisteredPlistNames.append(plistName)
    }
}

private final class RecordingPrivilegedXPCExchange:
    MacPrivilegedXPCExchanging
{
    var isInstalled = false
    private var responses: [Data]
    private(set) var validationCount = 0
    private(set) var operations: [String] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func validateEndpoint() throws -> String {
        validationCount += 1
        guard isInstalled else {
            throw MacInstallClientError.endpointUnavailable
        }
        return String(repeating: "c", count: 64)
    }

    func exchange(
        operation: String,
        payload _: Data
    ) throws -> (payload: Data, endpointIdentitySHA256: String) {
        guard isInstalled, !responses.isEmpty else {
            throw MacInstallClientError.endpointUnavailable
        }
        operations.append(operation)
        return (
            responses.removeFirst(),
            String(repeating: "c", count: 64)
        )
    }
}

private final class RecordingEndpointAuthenticator:
    MacOneShotEndpointAuthenticating
{
    let identity: String
    private(set) var processIdentifiers: [Int32?] = []

    init(identity: String = String(repeating: "c", count: 64)) {
        self.identity = identity
    }

    func authenticate(
        executableURL _: URL,
        processIdentifier: Int32?
    ) throws -> String {
        processIdentifiers.append(processIdentifier)
        return identity
    }
}

private final class RecordingMacOneShotProcessLauncher:
    MacOneShotProcessLaunching
{
    private let session: any MacOneShotClientSession
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?
    private(set) var launchCount = 0

    init(session: any MacOneShotClientSession) {
        self.session = session
    }

    func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> any MacOneShotClientSession {
        launchCount += 1
        self.executableURL = executableURL
        self.arguments = arguments
        return session
    }
}

private final class RecordingMacOneShotClientSession:
    MacOneShotClientSession
{
    let processIdentifier: Int32 = 4_242
    private var responses: [Data]
    private(set) var requests: [Data] = []
    private(set) var didCloseInput = false

    init(responses: [Data]) {
        self.responses = responses
    }

    func writeFrame(_ data: Data) throws {
        requests.append(data)
    }

    func readFrame() throws -> Data {
        guard !responses.isEmpty else {
            throw MacInstallClientError.invalidReservationResponse
        }
        return responses.removeFirst()
    }

    func closeInput() {
        didCloseInput = true
    }
}

private func reservationData(transactionID: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": 1,
            "transactionId": transactionID,
            "readyToken": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "journalSha256": String(repeating: "b", count: 64),
            "helperEndpointIdentitySha256": String(repeating: "c", count: 64),
            "expiresAtUnixMilliseconds": 99_999,
        ],
        options: [.sortedKeys]
    )
}

private func recoveryData(transactionID: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": 1,
            "transactionId": transactionID,
            "resultCode": "rolledBack",
            "verifiedOutcome": "oldTarget",
            "journalSha256": String(repeating: "b", count: 64),
        ],
        options: [.sortedKeys]
    )
}

private func statusData(
    transactionID: String,
    state: String,
    resultCode: String
) -> Data {
    try! JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": 1,
            "transactionId": transactionID,
            "state": state,
            "resultCode": resultCode,
            "journalSha256": String(repeating: "b", count: 64),
        ],
        options: [.sortedKeys]
    )
}

private func targetRequestData(
    targetClass: String,
    path: String,
    strategy: String? = nil,
    provider: String? = nil
) -> Data {
    var request: [String: Any] = [
            "target": [
                "class": targetClass,
                "pathHint": path,
            ],
        ]
    if let strategy { request["strategy"] = strategy }
    if let provider { request["provider"] = provider }
    return try! JSONSerialization.data(
        withJSONObject: request,
        options: [.sortedKeys]
    )
}

private final class ModernLaunchDaemonFixture {
    let rootURL: URL
    let applicationURL: URL
    let helperURL: URL
    let plistName = "com.example.desktop-updater.helper.plist"
    let infoDictionary: [String: Any] = [
        "DesktopUpdaterInstallHelperServiceID":
            "com.example.desktop-updater.helper",
        "DesktopUpdaterInstallHelperRequirement":
            "identifier com.example.desktop-updater.helper "
                + "and anchor apple generic",
        "DesktopUpdaterInstallHelperLaunchDaemonPlistName":
            "com.example.desktop-updater.helper.plist",
    ]

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        applicationURL = rootURL.appendingPathComponent(
            "Example.app",
            isDirectory: true
        )
        helperURL = applicationURL.appendingPathComponent(
            "Contents/Helpers/DesktopUpdaterInstallHelper"
        )
        let launchDaemonURL = applicationURL.appendingPathComponent(
            "Contents/Library/LaunchDaemons/\(plistName)"
        )
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: launchDaemonURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("signed helper".utf8).write(to: helperURL)
        let launchDaemon: [String: Any] = [
            "Label": "com.example.desktop-updater.helper",
            "BundleProgram":
                "Contents/Helpers/DesktopUpdaterInstallHelper",
            "MachServices": [
                "com.example.desktop-updater.helper": true,
            ],
        ]
        try PropertyListSerialization.data(
            fromPropertyList: launchDaemon,
            format: .xml,
            options: 0
        ).write(to: launchDaemonURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
