import CryptoKit
import Foundation
import Testing
@testable import WalletClient

/// The local test signer stands in for a YubiKey during development, so its assertions must pass the core's checks.
@Suite struct LocalSignerTests {
    private func owner(_ key: P256.Signing.PrivateKey, index: UInt32) -> OwnerKey {
        let raw = key.publicKey.rawRepresentation
        return OwnerKey(
            credentialId: LocalWebAuthnSigner(privateKey: key).credentialID.hexPrefixed,
            ownerIndex: index,
            publicKey: PublicKey(x: raw.prefix(32).hexPrefixed, y: raw.suffix(32).hexPrefixed),
            rpId: LocalWebAuthnSigner.relyingPartyID,
            requireUserVerification: false
        )
    }

    @Test func coreAcceptsLocalAssertions() async throws {
        let key = P256.Signing.PrivateKey()
        let owners = [owner(key, index: 0)]
        let initialOwners = try owners.map { try ownerBytes(key: $0.publicKey) }
        let address = try accountAddress(initialOwners: initialOwners)
        let call = try transferCall(token: nil, to: "0x000000000000000000000000000000000000dEaD", amount: "0x1")
        let price = GasPrice(maxFeePerGas: "0x1", maxPriorityFeePerGas: "0x1")
        let op = try buildUserOperation(
            sender: address, nonce: "0x0", deployed: false, initialOwners: initialOwners, calls: [call],
            gasPrice: price, signingOwnerIndex: 0
        )
        let review = try reviewUserOperation(op: op, chainId: 84532, tokens: [], functionSignatures: [])
        let assertion = try await LocalWebAuthnSigner(privateKey: key).assert(challenge: try Data(hex: review.hash), allowedCredentialIDs: [], requireUserVerification: false)
        let signed = try signUserOperation(op: op, chainId: 84532, assertion: assertion, owners: owners, initialOwners: initialOwners)
        #expect(signed.signature.count > 600)

        // A different key's assertion is refused with a readable error.
        let stranger = try await LocalWebAuthnSigner(privateKey: P256.Signing.PrivateKey())
            .assert(challenge: try Data(hex: review.hash), allowedCredentialIDs: [], requireUserVerification: false)
        #expect(throws: CoreError.self) {
            try signUserOperation(op: op, chainId: 84532, assertion: stranger, owners: owners, initialOwners: initialOwners)
        }
    }

    @Test func userOperationJSONMatchesBundlerShape() throws {
        let op = UserOperation(
            sender: "0x2c12B943Dc11D552Fa5648796BD0e85Ac4ddE92b", nonce: "0x0", initCode: "0x", callData: "0x",
            callGasLimit: "0x1", verificationGasLimit: "0x2", preVerificationGas: "0x3", maxFeePerGas: "0x4",
            maxPriorityFeePerGas: "0x5", paymasterAndData: "0x", signature: "0x"
        )
        let json = try JSONValue(encoding: op)
        #expect(json["callGasLimit"] == "0x1")
        #expect(json["paymasterAndData"] == "0x")
    }
}
