import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class HelperServerTests: XCTestCase {
    func testPreparePersistsJournalAndStartsMonitorBeforeReturning() throws {
        let fixture = ServerFixture()
        let reservation = try fixture.server.prepareInstall(fixture.request())

        XCTAssertEqual(fixture.events, ["journal", "monitor"])
        XCTAssertEqual(reservation.journalSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(
            fixture.server.status(transactionID: reservation.transactionID),
            .prepared
        )
    }

    func testCallerExitBeforeCommitCancelsReservation() throws {
        let fixture = ServerFixture()
        let reservation = try fixture.server.prepareInstall(fixture.request())
        try fixture.server.callerDidExit(transactionID: reservation.transactionID)
        XCTAssertEqual(
            fixture.server.status(transactionID: reservation.transactionID),
            .cancelled
        )
    }

    func testCommitTimeoutDuplicateCommitAndCancellationAfterCommitFailClosed()
        throws
    {
        let fixture = ServerFixture()
        let expired = try fixture.server.prepareInstall(fixture.request(expiresAt: 10))
        XCTAssertThrowsError(
            try fixture.server.commitAfterExit(
                transactionID: expired.transactionID,
                readyToken: expired.readyToken,
                nowUnixMilliseconds: 11
            )
        )
        XCTAssertEqual(fixture.server.status(transactionID: expired.transactionID), .expired)

        let committed = try fixture.server.prepareInstall(
            fixture.request(transactionID: "00000000-0000-4000-8000-000000000002")
        )
        try fixture.server.commitAfterExit(
            transactionID: committed.transactionID,
            readyToken: committed.readyToken,
            nowUnixMilliseconds: 10
        )
        XCTAssertThrowsError(
            try fixture.server.commitAfterExit(
                transactionID: committed.transactionID,
                readyToken: committed.readyToken,
                nowUnixMilliseconds: 10
            )
        )
        XCTAssertThrowsError(
            try fixture.server.cancelReservation(
                transactionID: committed.transactionID,
                readyToken: committed.readyToken
            )
        )
    }

    func testTwoCallersCannotReserveTheSameCanonicalTarget() throws {
        let fixture = ServerFixture()
        _ = try fixture.server.prepareInstall(fixture.request())
        XCTAssertThrowsError(
            try fixture.server.prepareInstall(
                fixture.request(
                    transactionID: "00000000-0000-4000-8000-000000000002"
                )
            )
        ) { error in
            XCTAssertEqual(error as? HelperServerError, .targetBusy)
        }
    }

    func testUnauthenticatedRequestCannotCreateJournalOrReservation() {
        let fixture = ServerFixture()
        XCTAssertThrowsError(
            try fixture.server.prepareInstall(fixture.request(authenticated: false))
        )
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testDurableJournalUsesDerivedNameAndExclusiveCreation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = ServerFixture()
        let request = fixture.request()
        let persister = DurableInitialJournalPersister(
            journalDirectoryURL: directory
        )
        let digest = try persister.persistInitialJournal(request)
        let journalURL = directory.appendingPathComponent(
            ".desktop-updater-journal-\(request.transactionID).json"
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL))
                as? [String: Any]
        )
        XCTAssertEqual(object["state"] as? String, "prepared")
        XCTAssertEqual(object["transactionId"] as? String, request.transactionID)
        XCTAssertEqual(digest.count, 64)
        XCTAssertThrowsError(try persister.persistInitialJournal(request))
    }
}

private final class ServerFixture {
    var events: [String] = []
    lazy var journal = TestJournal(events: self)
    lazy var monitor = TestMonitor(events: self)
    lazy var server = HelperServer(
        store: ReservationStore(),
        journalPersister: journal,
        callerMonitor: monitor
    )

    func request(
        transactionID: String = "00000000-0000-4000-8000-000000000001",
        expiresAt: Int64 = 100,
        authenticated: Bool = true
    ) -> HelperPrepareInstallRequest {
        HelperPrepareInstallRequest(
            transactionID: transactionID,
            targetIdentity: "com.example.app:/Applications/Example.app",
            readyToken: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            callerProcessIdentifier: 42,
            expiresAtUnixMilliseconds: expiresAt,
            authenticatedSessionSHA256: authenticated
                ? String(repeating: "f", count: 64)
                : ""
        )
    }
}

private final class TestJournal: InitialJournalPersisting {
    private unowned let fixture: ServerFixture

    init(events: ServerFixture) {
        fixture = events
    }

    func persistInitialJournal(_ request: HelperPrepareInstallRequest) throws
        -> String
    {
        fixture.events.append("journal")
        return String(repeating: "a", count: 64)
    }
}

private final class TestMonitor: CallerExitMonitoring {
    private unowned let fixture: ServerFixture

    init(events: ServerFixture) {
        fixture = events
    }

    func startMonitoring(
        processIdentifier _: Int32,
        transactionID _: String
    ) throws {
        fixture.events.append("monitor")
    }
}
