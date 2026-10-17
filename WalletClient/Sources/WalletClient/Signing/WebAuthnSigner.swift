import CryptoKit
import Foundation
import P256WalletCore

/// Anything that can produce WebAuthn assertions for one or more credentials: the security key prompt, or a local
/// test key. Assertions go to the core unmodified, which checks them.
public protocol WebAuthnSigner: Sendable {
    /// Signs `challenge`, restricted to the given credential IDs. Implementations may block on user interaction.
    func assert(challenge: Data, allowedCredentialIDs: [Data]) async throws -> Assertion
}

/// A Secure Enclave or software P-256 key that answers like a security key.
///
/// The smart wallet only checks the challenge, the `type` field, the user-present flag and the signature, so a local
/// key that formats its output like a security key is indistinguishable onchain. For development and tests.
public struct LocalWebAuthnSigner: WebAuthnSigner {
    public static let origin = "https://p256wallet.dev"

    public let credentialID: Data
    private let signMessage: @Sendable (Data) throws -> Data

    /// `signMessage` receives the raw message (CryptoKit hashes it with SHA-256) and returns a DER signature.
    public init(credentialID: Data, signMessage: @escaping @Sendable (Data) throws -> Data) {
        self.credentialID = credentialID
        self.signMessage = signMessage
    }

    /// A software key whose credential ID is the SHA-256 of its uncompressed public key.
    public init(privateKey: P256.Signing.PrivateKey) {
        self.init(credentialID: Data(SHA256.hash(data: privateKey.publicKey.x963Representation))) { message in
            try privateKey.signature(for: message).derRepresentation
        }
    }

    public func assert(challenge: Data, allowedCredentialIDs: [Data]) async throws -> Assertion {
        let rpIDHash = Data(SHA256.hash(data: Data("p256wallet.dev".utf8)))
        let flags: UInt8 = 0x05 // user present + user verified
        let authenticatorData = rpIDHash + Data([flags, 0, 0, 0, 0])
        let clientDataJSON = Data(
            #"{"type":"webauthn.get","challenge":"\#(challenge.base64URL)","origin":"\#(Self.origin)","crossOrigin":false}"#.utf8
        )
        let der = try signMessage(authenticatorData + Data(SHA256.hash(data: clientDataJSON)))
        return Assertion(
            credentialId: credentialID.hexPrefixed,
            authenticatorData: authenticatorData.hexPrefixed,
            clientDataJson: clientDataJSON.hexPrefixed,
            signature: der.hexPrefixed
        )
    }
}

private extension Data {
    /// Base64url without padding, as WebAuthn encodes the challenge.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
