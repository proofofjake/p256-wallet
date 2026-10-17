import Foundation

public enum SmartWalletError: Error, LocalizedError, Equatable {
    case challengeNotFound
    case typeNotFound

    public var errorDescription: String? {
        switch self {
        case .challengeNotFound: return "Security key response did not contain the expected challenge"
        case .typeNotFound: return "Security key response was not a webauthn.get assertion"
        }
    }
}

/// Encoding helpers for Coinbase Smart Wallet v1 (github.com/coinbase/smart-wallet).
///
/// Owners are stored as bytes: 32 bytes for an Ethereum address, 64 bytes (`x || y`) for a P-256 key.
/// P-256 owners sign WebAuthn assertions, verified onchain with the RIP-7212 precompile.
public enum CoinbaseSmartWallet {
    public static let factory = Address("0x0BA5ED0c6AA8c49038F819E587E2633c4A9F428a")!
    public static let entryPoint = UserOperation.entryPointV06

    /// ERC-1271 magic value returned by `isValidSignature` on success.
    public static let erc1271MagicValue = Data([0x16, 0x26, 0xba, 0x7e])

    /// ERC-6492 suffix marking a signature from a not-yet-deployed account.
    public static let erc6492MagicSuffix = try! Data(hex: "6492649264926492649264926492649264926492649264926492649264926492")

    public struct Call: Sendable, Equatable {
        public let target: Address
        public let value: UInt256
        public let data: Data

        public init(target: Address, value: UInt256 = 0, data: Data = Data()) {
            self.target = target
            self.value = value
            self.data = data
        }
    }

    public static func ownerBytes(_ key: P256PublicKey) -> Data {
        key.raw
    }

    // MARK: Factory

    public static func createAccountCalldata(owners: [Data], nonce: UInt256 = 0) -> Data {
        ABI.encodeCall("createAccount(bytes[],uint256)", [.array(owners.map { .bytes($0) }), .uint(nonce)])
    }

    public static func getAddressCalldata(owners: [Data], nonce: UInt256 = 0) -> Data {
        ABI.encodeCall("getAddress(bytes[],uint256)", [.array(owners.map { .bytes($0) }), .uint(nonce)])
    }

    /// `initCode` for the first user operation: factory address followed by the `createAccount` call.
    public static func initCode(owners: [Data], nonce: UInt256 = 0) -> Data {
        factory.data + createAccountCalldata(owners: owners, nonce: nonce)
    }

    /// The counterfactual account address. Identical on every chain where the factory is deployed.
    public static func accountAddress(owners: [Data], nonce: UInt256 = 0, client: EthereumClient) async throws -> Address {
        let result = try await client.call(to: factory, data: getAddressCalldata(owners: owners, nonce: nonce))
        return try ABIDecoder(result).address(at: 0)
    }

    // MARK: Account calls

    public static func executeCalldata(_ call: Call) -> Data {
        ABI.encodeCall("execute(address,uint256,bytes)", [.address(call.target), .uint(call.value), .bytes(call.data)])
    }

    public static func executeBatchCalldata(_ calls: [Call]) -> Data {
        ABI.encodeCall("executeBatch((address,uint256,bytes)[])", [
            .array(calls.map { .tuple([.address($0.target), .uint($0.value), .bytes($0.data)]) }),
        ])
    }

    /// Single calls use `execute`, multiple use `executeBatch`.
    public static func callData(for calls: [Call]) -> Data {
        calls.count == 1 ? executeCalldata(calls[0]) : executeBatchCalldata(calls)
    }

    /// Owner management is `onlyOwner`, which includes the account itself, so it is routed through `execute`.
    public static func addOwnerPublicKeyCall(account: Address, key: P256PublicKey) -> Call {
        Call(target: account, data: ABI.encodeCall("addOwnerPublicKey(bytes32,bytes32)", [.fixedBytes(key.x), .fixedBytes(key.y)]))
    }

    public static func nextOwnerIndex(account: Address, client: EthereumClient) async throws -> Int {
        try ABIDecoder(try await client.call(to: account, data: ABI.selector("nextOwnerIndex()"))).int(at: 0)
    }

    // MARK: Signatures

    /// `abi.encode(WebAuthnAuth)`: the signature data for a P-256 owner.
    ///
    /// The onchain verifier slices `clientDataJSON` at `challengeIndex` and `typeIndex` and compares against
    /// `"challenge":"<base64url(challenge)>"` and `"type":"webauthn.get"`, so the byte offsets must be exact.
    public static func encodeWebAuthnAuth(_ assertion: WebAuthnAssertion, challenge: Data) throws -> Data {
        let json = Data(assertion.clientDataJSON)
        let challengeNeedle = Data(#""challenge":"\#(challenge.base64URLEncodedString)""#.utf8)
        let typeNeedle = Data(#""type":"webauthn.get""#.utf8)
        guard let challengeRange = json.firstRange(of: challengeNeedle) else { throw SmartWalletError.challengeNotFound }
        guard let typeRange = json.firstRange(of: typeNeedle) else { throw SmartWalletError.typeNotFound }
        let signature = assertion.signature.normalized
        return ABI.encode([.tuple([
            .bytes(assertion.authenticatorData),
            .bytes(json), // `string clientDataJSON` encodes identically to bytes
            .uint(UInt256(challengeRange.lowerBound - json.startIndex)),
            .uint(UInt256(typeRange.lowerBound - json.startIndex)),
            .uint(signature.r),
            .uint(signature.s),
        ])])
    }

    /// `abi.encode(SignatureWrapper(ownerIndex, signatureData))`, the format `UserOperation.signature`
    /// and `isValidSignature` expect.
    public static func wrapSignature(ownerIndex: Int, signatureData: Data) -> Data {
        ABI.encode([.tuple([.uint(UInt256(ownerIndex)), .bytes(signatureData)])])
    }

    /// Placeholder used during gas estimation. Same shape and similar length as a real security-key assertion.
    public static func dummySignature(ownerIndex: Int) -> Data {
        let dummyChallenge = Data(repeating: 0xff, count: 32)
        let assertion = WebAuthnAssertion(
            credentialID: Data(),
            authenticatorData: Data(repeating: 0x49, count: 32) + Data([0x05, 0, 0, 0, 0]),
            clientDataJSON: Data(
                #"{"type":"webauthn.get","challenge":"\#(dummyChallenge.base64URLEncodedString)","origin":"https://wallet.example.com","crossOrigin":false}"#.utf8
            ),
            signature: P256Signature(r: P256Signature.halfN, s: P256Signature.halfN)
        )
        // The needles are built from the same challenge, so this cannot fail.
        let data = try! encodeWebAuthnAuth(assertion, challenge: dummyChallenge)
        return wrapSignature(ownerIndex: ownerIndex, signatureData: data)
    }

    /// EIP-712 wrapper the account applies before verifying ERC-1271 signatures, so a signature for one
    /// account (or chain) can't be replayed on another owned by the same key.
    public static func replaySafeHash(_ hash: Data, account: Address, chainID: UInt64) -> Data {
        let domainSeparator = Keccak256.hash(ABI.encode([
            .fixedBytes(Keccak256.hash("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")),
            .fixedBytes(Keccak256.hash("Coinbase Smart Wallet")),
            .fixedBytes(Keccak256.hash("1")),
            .uint(UInt256(chainID)),
            .address(account),
        ]))
        let structHash = Keccak256.hash(ABI.encode([
            .fixedBytes(Keccak256.hash("CoinbaseSmartWalletMessage(bytes32 hash)")),
            .fixedBytes(hash),
        ]))
        return Keccak256.hash(Data([0x19, 0x01]) + domainSeparator + structHash)
    }

    /// ERC-6492 wrapping so verifiers can check a signature before the account is deployed.
    public static func erc6492Wrap(signature: Data, owners: [Data], nonce: UInt256 = 0) -> Data {
        ABI.encode([
            .address(factory),
            .bytes(createAccountCalldata(owners: owners, nonce: nonce)),
            .bytes(signature),
        ]) + erc6492MagicSuffix
    }

    public static func isValidSignature(account: Address, hash: Data, signature: Data, client: EthereumClient) async throws -> Bool {
        let call = ABI.encodeCall("isValidSignature(bytes32,bytes)", [.fixedBytes(hash), .bytes(signature)])
        do {
            let result = try await client.call(to: account, data: call)
            return result.prefix(4) == erc1271MagicValue
        } catch is RPCError {
            return false
        }
    }
}

/// EIP-191 `personal_sign` message hash.
public func personalMessageHash(_ message: Data) -> Data {
    Keccak256.hash(Data("\u{19}Ethereum Signed Message:\n\(message.count)".utf8) + message)
}
