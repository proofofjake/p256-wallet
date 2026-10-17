import CryptoKit
import Foundation

/// A WebAuthn assertion: what a security key returns when asked to sign a challenge.
public struct WebAuthnAssertion: Sendable, Equatable {
    public let credentialID: Data
    public let authenticatorData: Data
    public let clientDataJSON: Data
    public let signature: P256Signature

    public init(credentialID: Data, authenticatorData: Data, clientDataJSON: Data, signature: P256Signature) {
        self.credentialID = credentialID
        self.authenticatorData = authenticatorData
        self.clientDataJSON = clientDataJSON
        self.signature = signature
    }

    /// The digest the authenticator actually signed: `sha256(authenticatorData || sha256(clientDataJSON))`.
    public var signedMessageHash: Data {
        Data(SHA256.hash(data: authenticatorData + Data(SHA256.hash(data: clientDataJSON))))
    }

    /// Checks the signature locally against a public key. Useful as a sanity check before submitting.
    public func verify(publicKey: P256PublicKey) -> Bool {
        guard let key = try? P256.Signing.PublicKey(rawRepresentation: publicKey.raw),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature.raw) else { return false }
        return key.isValidSignature(sig, for: authenticatorData + Data(SHA256.hash(data: clientDataJSON)))
    }
}

/// A newly registered credential.
public struct WebAuthnRegistration: Sendable, Equatable {
    public let credentialID: Data
    public let publicKey: P256PublicKey

    public init(credentialID: Data, publicKey: P256PublicKey) {
        self.credentialID = credentialID
        self.publicKey = publicKey
    }

    /// Extracts the credential public key from a WebAuthn attestation object (CBOR map with `authData`).
    public init(attestationObject: Data, credentialID: Data) throws {
        let object = try CBORDecoder.decode(attestationObject)
        guard let authData = object["authData"]?.bytesValue else {
            throw P256Error.invalidAuthenticatorData("attestation object has no authData")
        }
        let parsed = try AuthenticatorData(authData)
        guard let publicKey = parsed.credentialPublicKey else {
            throw P256Error.invalidAuthenticatorData("no attested credential data")
        }
        if let parsedID = parsed.credentialID, parsedID != credentialID {
            throw P256Error.invalidAuthenticatorData("credential ID mismatch")
        }
        self.init(credentialID: credentialID, publicKey: publicKey)
    }
}

/// Parsed WebAuthn authenticator data.
public struct AuthenticatorData: Sendable {
    public static let flagUserPresent: UInt8 = 0x01
    public static let flagUserVerified: UInt8 = 0x04
    public static let flagAttestedCredentialData: UInt8 = 0x40

    public let rpIDHash: Data
    public let flags: UInt8
    public let signCount: UInt32
    public let credentialID: Data?
    public let credentialPublicKey: P256PublicKey?

    public init(_ data: Data) throws {
        let bytes = Data(data)
        guard bytes.count >= 37 else { throw P256Error.invalidAuthenticatorData("too short") }
        rpIDHash = bytes.subdata(in: 0..<32)
        flags = bytes[32]
        signCount = bytes.subdata(in: 33..<37).reduce(0) { $0 << 8 | UInt32($1) }

        guard flags & Self.flagAttestedCredentialData != 0 else {
            credentialID = nil
            credentialPublicKey = nil
            return
        }
        // aaguid (16) | credentialIdLength (2) | credentialId | credentialPublicKey (COSE)
        var offset = 37 + 16
        guard bytes.count >= offset + 2 else { throw P256Error.invalidAuthenticatorData("truncated") }
        let idLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        offset += 2
        guard bytes.count >= offset + idLength else { throw P256Error.invalidAuthenticatorData("truncated id") }
        credentialID = bytes.subdata(in: offset..<offset + idLength)
        offset += idLength
        let (coseKey, _) = try CBORDecoder.decodePrefix(bytes.subdata(in: offset..<bytes.count))
        credentialPublicKey = try P256PublicKey(coseKey: coseKey)
    }
}

/// Anything that can produce WebAuthn assertions for one or more credentials.
public protocol WebAuthnSigner: Sendable {
    /// Signs `challenge`, restricted to the given credential IDs. Implementations may block on user interaction.
    func assert(challenge: Data, allowedCredentialIDs: [Data]) async throws -> WebAuthnAssertion
}

/// A software or Secure Enclave P-256 key that emits WebAuthn-shaped assertions.
///
/// The smart wallet only checks the challenge, the `type` field, the UP flag and the signature, so a local key
/// that formats its output like a security key is indistinguishable onchain. Used for development and tests.
public struct LocalWebAuthnSigner: WebAuthnSigner {
    public static let origin = "https://p256wallet.dev"

    public let credentialID: Data
    public let publicKey: P256PublicKey
    private let signMessage: @Sendable (Data) throws -> Data

    /// `signMessage` receives the raw message (CryptoKit hashes it with SHA-256) and returns a DER signature.
    public init(credentialID: Data, publicKey: P256PublicKey, signMessage: @escaping @Sendable (Data) throws -> Data) {
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.signMessage = signMessage
    }

    public init(privateKey: P256.Signing.PrivateKey) throws {
        let publicKey = try P256PublicKey(raw: privateKey.publicKey.rawRepresentation)
        self.init(credentialID: Data(SHA256.hash(data: publicKey.raw)), publicKey: publicKey) { message in
            try privateKey.signature(for: message).derRepresentation
        }
    }

    public func assert(challenge: Data, allowedCredentialIDs: [Data]) async throws -> WebAuthnAssertion {
        let rpIDHash = Data(SHA256.hash(data: Data("p256wallet.dev".utf8)))
        let flags = AuthenticatorData.flagUserPresent | AuthenticatorData.flagUserVerified
        let authenticatorData = rpIDHash + Data([flags, 0, 0, 0, 0])
        let clientDataJSON = Data(
            #"{"type":"webauthn.get","challenge":"\#(challenge.base64URLEncodedString)","origin":"\#(Self.origin)","crossOrigin":false}"#.utf8
        )
        let der = try signMessage(authenticatorData + Data(SHA256.hash(data: clientDataJSON)))
        return WebAuthnAssertion(
            credentialID: credentialID,
            authenticatorData: authenticatorData,
            clientDataJSON: clientDataJSON,
            signature: try P256Signature(der: der)
        )
    }
}
