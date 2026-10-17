import CryptoKit
import Foundation
import Testing
@testable import WalletCore

/// Just enough CBOR encoding to build attestation objects for tests.
private enum TestCBOR {
    static func header(_ major: UInt8, _ value: Int) -> Data {
        switch value {
        case 0..<24: return Data([major << 5 | UInt8(value)])
        case 24..<256: return Data([major << 5 | 24, UInt8(value)])
        default: return Data([major << 5 | 25, UInt8(value >> 8), UInt8(value & 0xff)])
        }
    }

    static func int(_ value: Int) -> Data { value >= 0 ? header(0, value) : header(1, -1 - value) }
    static func bytes(_ data: Data) -> Data { header(2, data.count) + data }
    static func text(_ string: String) -> Data { header(3, string.utf8.count) + Data(string.utf8) }
    static func map(_ pairs: [(Data, Data)]) -> Data {
        pairs.reduce(header(5, pairs.count)) { $0 + $1.0 + $1.1 }
    }

    static func coseKey(_ key: P256PublicKey) -> Data {
        map([(int(1), int(2)), (int(3), int(-7)), (int(-1), int(1)), (int(-2), bytes(key.x)), (int(-3), bytes(key.y))])
    }
}

@Suite struct WebAuthnTests {
    @Test func parsesAttestationObject() throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = try P256PublicKey(raw: key.publicKey.rawRepresentation)
        let credentialID = Data((0..<48).map { UInt8($0) })

        let flags = AuthenticatorData.flagUserPresent | AuthenticatorData.flagAttestedCredentialData
        var authData = Data(SHA256.hash(data: Data("example.com".utf8)))
        authData += Data([flags, 0, 0, 0, 7])
        authData += Data(repeating: 0xaa, count: 16) // AAGUID
        authData += Data([0, UInt8(credentialID.count)]) + credentialID
        authData += TestCBOR.coseKey(publicKey)

        let attestation = TestCBOR.map([
            (TestCBOR.text("fmt"), TestCBOR.text("none")),
            (TestCBOR.text("attStmt"), TestCBOR.map([])),
            (TestCBOR.text("authData"), TestCBOR.bytes(authData)),
        ])

        let registration = try WebAuthnRegistration(attestationObject: attestation, credentialID: credentialID)
        #expect(registration.publicKey == publicKey)

        let parsed = try AuthenticatorData(authData)
        #expect(parsed.signCount == 7)
        #expect(parsed.credentialID == credentialID)
    }

    @Test func rejectsNonP256Key() throws {
        let rsaLike = TestCBOR.map([(TestCBOR.int(1), TestCBOR.int(3)), (TestCBOR.int(3), TestCBOR.int(-257))])
        #expect(throws: P256Error.self) { try P256PublicKey(coseKey: try CBORDecoder.decode(rsaLike)) }
    }

    @Test func derMatchesRaw() throws {
        let key = P256.Signing.PrivateKey()
        for _ in 0..<20 {
            let signature = try key.signature(for: Data("message".utf8))
            let fromDER = try P256Signature(der: signature.derRepresentation)
            let fromRaw = try P256Signature(raw: signature.rawRepresentation)
            #expect(fromDER == fromRaw)
        }
    }

    @Test func lowSNormalizationStillVerifies() throws {
        let key = P256.Signing.PrivateKey()
        let message = Data("normalize me".utf8)
        var sawHighS = false
        for _ in 0..<64 {
            let signature = try P256Signature(raw: try key.signature(for: message).rawRepresentation)
            let normalized = signature.normalized
            #expect(normalized.s <= P256Signature.halfN)
            if signature.s > P256Signature.halfN {
                sawHighS = true
                let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: normalized.raw)
                #expect(key.publicKey.isValidSignature(ecdsa, for: message))
            }
        }
        #expect(sawHighS, "64 signatures without a single high-s value is astronomically unlikely")
    }

    @Test func localSignerProducesVerifiableAssertion() async throws {
        let signer = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let challenge = Data(repeating: 0x42, count: 32)
        let assertion = try await signer.assert(challenge: challenge, allowedCredentialIDs: [signer.credentialID])
        #expect(assertion.verify(publicKey: signer.publicKey))

        let encoded = try CoinbaseSmartWallet.encodeWebAuthnAuth(assertion, challenge: challenge)
        let decoder = ABIDecoder(encoded)
        // Outer offset to the tuple, then members relative to it.
        let base = try decoder.int(at: 0)
        let json = try decoder.bytes(at: base + 32, base: base)
        let challengeIndex = try decoder.int(at: base + 64)
        let typeIndex = try decoder.int(at: base + 96)
        let s = try decoder.uint(at: base + 160)

        let needle = Data(#""challenge":"\#(challenge.base64URLEncodedString)""#.utf8)
        #expect(json.subdata(in: challengeIndex..<challengeIndex + needle.count) == needle)
        #expect(json.subdata(in: typeIndex..<typeIndex + 21) == Data(#""type":"webauthn.get""#.utf8))
        #expect(s <= P256Signature.halfN)
    }

    @Test func wrongChallengeIsRejected() async throws {
        let signer = try LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
        let assertion = try await signer.assert(challenge: Data(repeating: 1, count: 32), allowedCredentialIDs: [])
        #expect(throws: SmartWalletError.challengeNotFound) {
            try CoinbaseSmartWallet.encodeWebAuthnAuth(assertion, challenge: Data(repeating: 2, count: 32))
        }
    }

    @Test func dummySignatureIsWellFormed() throws {
        let dummy = CoinbaseSmartWallet.dummySignature(ownerIndex: 1)
        let decoder = ABIDecoder(dummy)
        let base = try decoder.int(at: 0)
        #expect(try decoder.int(at: base) == 1)
        #expect(dummy.count > 300)
    }

    @Test func base64URL() {
        let data = Data([0xfb, 0xff, 0xfe])
        #expect(data.base64URLEncodedString == "-__-")
        #expect(Data(base64URLEncoded: "-__-") == data)
        #expect(Data(repeating: 0, count: 32).base64URLEncodedString.count == 43)
    }
}
