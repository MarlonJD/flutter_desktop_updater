import XCTest
@testable import DesktopUpdaterKit

final class InstallTransactionTests: XCTestCase {
    func testJournalUsesExactDurableStateNames() throws {
        let journal = InstallTransactionJournal(
            ownerPID: 42,
            ownerProcessStart: "boot-a:100",
            nonce: "123e4567-e89b-42d3-a456-426614174000",
            packageID: "com.example.app",
            target: "/Applications/Example.app",
            prepared: "/Applications/.Example.app.prepared-123e4567-e89b-42d3-a456-426614174000",
            backup: "/Applications/.Example.app.backup-123e4567-e89b-42d3-a456-426614174000",
            stageProvenanceSHA256: String(repeating: "a", count: 64),
            state: .backupCreated
        )

        let encoded = try JSONEncoder().encode(journal)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["state"] as? String, "backupCreated")
        XCTAssertEqual(
            InstallTransactionState.allCases.map(\.rawValue),
            ["prepared", "backupCreated", "targetActivated", "completed"]
        )
    }

    func testJournalRejectsDeletionOutsideItsThreePaths() {
        let journal = InstallTransactionJournal.fixture

        XCTAssertTrue(journal.ownsPath(journal.target))
        XCTAssertTrue(journal.ownsPath(journal.prepared))
        XCTAssertTrue(journal.ownsPath(journal.backup))
        XCTAssertFalse(journal.ownsPath("/Users/outside"))
    }
}

private extension InstallTransactionJournal {
    static var fixture: InstallTransactionJournal {
        InstallTransactionJournal(
            ownerPID: 42,
            ownerProcessStart: "boot-a:100",
            nonce: "123e4567-e89b-42d3-a456-426614174000",
            packageID: "com.example.app",
            target: "/Applications/Example.app",
            prepared: "/Applications/.Example.app.prepared-123e4567-e89b-42d3-a456-426614174000",
            backup: "/Applications/.Example.app.backup-123e4567-e89b-42d3-a456-426614174000",
            stageProvenanceSHA256: String(repeating: "a", count: 64),
            state: .prepared
        )
    }
}
