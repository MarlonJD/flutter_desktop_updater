import CommonCrypto
import Foundation

public struct HelperAuthenticationRequestV1: Equatable {
    public var schemaVersion: Int
    public var protocolVersion: Int
    public var transactionID: String
    public var policyID: String
    public var policySHA256: String
    public var requestSHA256: String
    public var helperSHA256: String
    public var transactionNonce: String
    public var callerAuditToken: Data

    public init(
        schemaVersion: Int,
        protocolVersion: Int,
        transactionID: String,
        policyID: String,
        policySHA256: String,
        requestSHA256: String,
        helperSHA256: String,
        transactionNonce: String,
        callerAuditToken: Data
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.transactionID = transactionID
        self.policyID = policyID
        self.policySHA256 = policySHA256
        self.requestSHA256 = requestSHA256
        self.helperSHA256 = helperSHA256
        self.transactionNonce = transactionNonce
        self.callerAuditToken = callerAuditToken
    }
}

enum HelperProtocolValidation {
    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character)
        }
    }

    static func isTransactionID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return uuid.uuidString.lowercased() == value
    }

    static func isReadyToken(_ value: String) -> Bool {
        value.count >= 43 && value.count <= 128 && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    static func isDottedIdentifier(_ value: String) -> Bool {
        guard let range = value.range(
            of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]{1,126}[A-Za-z0-9])?$"#,
            options: .regularExpression
        ) else {
            return false
        }
        return range == value.startIndex ..< value.endIndex
    }
}

enum HelperSHA256 {
    static func hex(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        _ = CC_SHA256_Init(&context)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = min(bytes.count - offset, Int(CC_LONG.max))
                _ = CC_SHA256_Update(
                    &context,
                    baseAddress.advanced(by: offset),
                    CC_LONG(count)
                )
                offset += count
            }
        }
        var digest = [UInt8](
            repeating: 0,
            count: Int(CC_SHA256_DIGEST_LENGTH)
        )
        _ = CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
