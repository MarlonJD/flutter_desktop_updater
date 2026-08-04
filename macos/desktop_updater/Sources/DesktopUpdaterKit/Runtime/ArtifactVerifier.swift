import CryptoKit
import Foundation

public enum ArtifactVerifier {
    public static func verifyIndexSignature(
        _ index: ReleaseIndex,
        pinnedPublicKeysById: [String: Data]
    ) throws -> Bool {
        guard let signature = index.signature,
              signature.algorithm == "ed25519",
              !signature.publicKeyId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              let publicKeyData = pinnedPublicKeysById[signature.publicKeyId],
              publicKeyData.count == 32,
              let signatureData = Data(base64Encoded: signature.value),
              signatureData.count == 64
        else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyData
        )
        return publicKey.isValidSignature(
            signatureData,
            for: try index.canonicalSignatureBytes()
        )
    }

    public static func verifyDescriptorSignature(
        _ descriptor: ReleaseDescriptor,
        pinnedPublicKeysById: [String: Data]
    ) throws -> Bool {
        guard let signature = descriptor.signature,
              signature.algorithm == "ed25519",
              let publicKeyData = pinnedPublicKeysById[signature.publicKeyId],
              publicKeyData.count == 32,
              let signatureData = Data(base64Encoded: signature.value),
              signatureData.count == 64
        else {
            return false
        }
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicKeyData
        )
        return publicKey.isValidSignature(
            signatureData,
            for: try descriptor.canonicalSignatureBytes()
        )
    }
}
