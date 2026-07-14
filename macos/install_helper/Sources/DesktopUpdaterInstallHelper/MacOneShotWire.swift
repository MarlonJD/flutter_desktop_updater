import CoreFoundation
import Foundation

protocol MacOneShotServiceRunning: AnyObject {
    func run() throws
}

protocol MacOneShotWireChannel: AnyObject {
    func readFrame() throws -> Data
    func writeFrame(_ data: Data) throws
}

protocol MacCallerExitMonitoring: AnyObject {
    func waitForExit(expiresAtUnixMilliseconds: Int64) throws
}

protocol MacCallerExitMonitorCreating: AnyObject {
    func makeMonitor(
        processIdentifier: Int64
    ) throws -> any MacCallerExitMonitoring
}

enum MacOneShotWireError: Error, Equatable {
    case invalidMessage
    case unsupportedOperation
    case invalidFrameLength
    case truncatedFrame
}

final class MacLengthPrefixedFileHandleChannel: MacOneShotWireChannel {
    static let maximumFrameLength = 1_048_576

    private let input: FileHandle
    private let output: FileHandle

    init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    func readFrame() throws -> Data {
        let header = try readExactly(4)
        let length = header.reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
        guard (1 ... Self.maximumFrameLength).contains(length) else {
            throw MacOneShotWireError.invalidFrameLength
        }
        return try readExactly(length)
    }

    func writeFrame(_ data: Data) throws {
        guard (1 ... Self.maximumFrameLength).contains(data.count) else {
            throw MacOneShotWireError.invalidFrameLength
        }
        let length = UInt32(data.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ])
        frame.append(data)
        output.write(frame)
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data()
        while result.count < count {
            let fragment = input.readData(ofLength: count - result.count)
            guard !fragment.isEmpty else {
                throw MacOneShotWireError.truncatedFrame
            }
            result.append(fragment)
        }
        return result
    }
}

final class MacOneShotServiceRuntime {
    private let session: MacOneShotInstallSession
    private let callerMonitorFactory: any MacCallerExitMonitorCreating

    init(
        session: MacOneShotInstallSession,
        callerMonitorFactory: any MacCallerExitMonitorCreating
    ) {
        self.session = session
        self.callerMonitorFactory = callerMonitorFactory
    }

    func run(channel: any MacOneShotWireChannel) throws {
        let requestData = try channel.readFrame()
        let request = try NativeInstallTransactionRequestV1.parse(requestData)
        let monitor = try callerMonitorFactory.makeMonitor(
            processIdentifier: request.caller.processIdentifier
        )
        let reservation = try session.prepare(requestData: requestData)
        do {
            try channel.writeFrame(try macEncodeReservation(reservation))

            let command = try MacOneShotWireCommand.parse(
                try channel.readFrame()
            )
            switch command.operation {
            case "commitAfterExit":
                _ = try session.acceptCommit(
                    transactionID: command.transactionID,
                    readyToken: command.readyToken,
                    journalSHA256: command.journalSHA256,
                    helperEndpointIdentitySHA256:
                        command.helperEndpointIdentitySHA256
                )
                do {
                    try channel.writeFrame(
                        try macEncodeReservation(reservation)
                    )
                    try monitor.waitForExit(
                        expiresAtUnixMilliseconds:
                            reservation.expiresAtUnixMilliseconds
                    )
                } catch {
                    _ = try session.cancelCommitAwaitingCallerExit()
                    throw error
                }
                _ = try session.executeAfterCallerExit()
            case "cancelReservation":
                _ = try session.cancel(
                    transactionID: command.transactionID,
                    readyToken: command.readyToken,
                    journalSHA256: command.journalSHA256,
                    helperEndpointIdentitySHA256:
                        command.helperEndpointIdentitySHA256
                )
                try channel.writeFrame(
                    try macEncodeCancellation(reservation)
                )
            default:
                throw MacOneShotWireError.unsupportedOperation
            }
        } catch {
            _ = try? session.cancel(
                transactionID: reservation.transactionID,
                readyToken: reservation.readyToken,
                journalSHA256: reservation.journalSHA256,
                helperEndpointIdentitySHA256:
                    reservation.helperEndpointIdentitySHA256
            )
            throw error
        }
    }

}

func macEncodeReservation(
    _ value: MacOneShotReservationV1
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": value.protocolVersion,
            "transactionId": value.transactionID,
            "readyToken": value.readyToken,
            "journalSha256": value.journalSHA256,
            "helperEndpointIdentitySha256":
                value.helperEndpointIdentitySHA256,
            "expiresAtUnixMilliseconds":
                value.expiresAtUnixMilliseconds,
        ],
        options: [.sortedKeys]
    )
}

func macEncodeCancellation(
    _ value: MacOneShotReservationV1
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "protocolVersion": value.protocolVersion,
            "transactionId": value.transactionID,
            "resultCode": "rolledBack",
            "verifiedOutcome": "oldTarget",
            "journalSha256": value.journalSHA256,
        ],
        options: [.sortedKeys]
    )
}

struct MacOneShotWireCommand {
    let operation: String
    let transactionID: String
    let readyToken: String
    let journalSHA256: String
    let helperEndpointIdentitySHA256: String

    static func parse(_ data: Data) throws -> Self {
        let value = try NativeStrictJSON.decode(data)
        guard let object = value as? [String: Any],
              Set(object.keys) == [
                  "operation",
                  "protocolVersion",
                  "transactionId",
                  "readyToken",
                  "journalSha256",
                  "helperEndpointIdentitySha256",
              ],
              integer(object["protocolVersion"]) == 1,
              let operation = object["operation"] as? String,
              ["commitAfterExit", "cancelReservation"].contains(operation),
              let transactionID = object["transactionId"] as? String,
              isTransactionID(transactionID),
              let readyToken = object["readyToken"] as? String,
              isReadyToken(readyToken),
              let journalSHA256 = object["journalSha256"] as? String,
              isSHA256(journalSHA256),
              let endpoint = object["helperEndpointIdentitySha256"]
                as? String,
              isSHA256(endpoint) else {
            throw MacOneShotWireError.invalidMessage
        }
        return Self(
            operation: operation,
            transactionID: transactionID,
            readyToken: readyToken,
            journalSHA256: journalSHA256,
            helperEndpointIdentitySHA256: endpoint
        )
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else {
            return nil
        }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func isTransactionID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isReadyToken(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9_-]{43}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil
    }
}
