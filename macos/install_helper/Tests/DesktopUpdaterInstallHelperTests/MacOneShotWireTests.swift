import Foundation
import XCTest
@testable import DesktopUpdaterInstallHelper

final class MacOneShotWireTests: XCTestCase {
    func testFileHandleChannelReadsAndWritesBigEndianLengthFrames() throws {
        let input = Pipe()
        let output = Pipe()
        try input.fileHandleForWriting.write(contentsOf: framed(Data("request".utf8)))
        input.fileHandleForWriting.closeFile()
        let channel = MacLengthPrefixedFileHandleChannel(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )

        XCTAssertEqual(try channel.readFrame(), Data("request".utf8))
        try channel.writeFrame(Data("response".utf8))
        output.fileHandleForWriting.closeFile()

        XCTAssertEqual(
            output.fileHandleForReading.readDataToEndOfFile(),
            framed(Data("response".utf8))
        )
    }

    func testFileHandleChannelRejectsInvalidOrTruncatedFrames() throws {
        for (candidate, expected) in [
            (Data([0, 0, 0, 0]), MacOneShotWireError.invalidFrameLength),
            (Data([0, 16, 0, 1]), MacOneShotWireError.invalidFrameLength),
            (Data([0, 0, 0]), MacOneShotWireError.truncatedFrame),
            (Data([0, 0, 0, 4]) + Data("abc".utf8),
             MacOneShotWireError.truncatedFrame),
        ] {
            let input = Pipe()
            try input.fileHandleForWriting.write(contentsOf: candidate)
            input.fileHandleForWriting.closeFile()
            let channel = MacLengthPrefixedFileHandleChannel(
                input: input.fileHandleForReading,
                output: Pipe().fileHandleForWriting
            )

            XCTAssertThrowsError(try channel.readFrame()) { error in
                XCTAssertEqual(error as? MacOneShotWireError, expected)
            }
        }
    }

    func testFileHandleChannelRejectsEmptyAndOversizedOutputFrames() throws {
        let channel = MacLengthPrefixedFileHandleChannel(
            input: Pipe().fileHandleForReading,
            output: Pipe().fileHandleForWriting
        )

        XCTAssertThrowsError(try channel.writeFrame(Data())) { error in
            XCTAssertEqual(
                error as? MacOneShotWireError,
                .invalidFrameLength
            )
        }
        XCTAssertThrowsError(
            try channel.writeFrame(Data(repeating: 0, count: 1_048_577))
        ) { error in
            XCTAssertEqual(
                error as? MacOneShotWireError,
                .invalidFrameLength
            )
        }
    }

    func testSystemCallerMonitorWaitsForRegisteredProcessExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.05"]
        try process.run()
        let monitor = try SystemMacCallerExitMonitorFactory().makeMonitor(
            processIdentifier: Int64(process.processIdentifier)
        )

        try monitor.waitForExit(
            expiresAtUnixMilliseconds: unixMilliseconds() + 3_000
        )
        process.waitUntilExit()

        XCTAssertFalse(process.isRunning)
    }

    func testSystemCallerMonitorFailsClosedAtReservationExpiry() throws {
        let monitor = try SystemMacCallerExitMonitorFactory().makeMonitor(
            processIdentifier: Int64(ProcessInfo.processInfo.processIdentifier)
        )

        XCTAssertThrowsError(
            try monitor.waitForExit(
                expiresAtUnixMilliseconds: unixMilliseconds() + 20
            )
        ) { error in
            XCTAssertEqual(
                error as? MacCallerExitMonitorError,
                .timedOut
            )
        }
    }
}

private func framed(_ payload: Data) -> Data {
    let count = UInt32(payload.count)
    return Data([
        UInt8((count >> 24) & 0xff),
        UInt8((count >> 16) & 0xff),
        UInt8((count >> 8) & 0xff),
        UInt8(count & 0xff),
    ]) + payload
}

private func unixMilliseconds() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
}
