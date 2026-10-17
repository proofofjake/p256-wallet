import Foundation

/// A P-256 key that owns the account, as the signer needs to see it.
public struct OwnerKey: Sendable, Hashable {
    public let credentialID: Data
    public let ownerIndex: Int
    public let publicKey: P256PublicKey

    public init(credentialID: Data, ownerIndex: Int, publicKey: P256PublicKey) {
        self.credentialID = credentialID
        self.ownerIndex = ownerIndex
        self.publicKey = publicKey
    }
}

/// A user operation with gas and paymaster data filled in, ready to be signed.
public struct PreparedOperation: Sendable {
    public let userOperation: UserOperation
    public let hash: Data
    public let isSponsored: Bool
    public let deploysAccount: Bool
    /// ETH the account must hold: the gas ceiling (unless sponsored) plus any value sent.
    public let requiredBalance: UInt256
    /// Gas ceiling in wei. Actual cost is usually much lower.
    public var maxGasCost: UInt256 { isSponsored ? 0 : userOperation.maxCost }
}

public struct SignedMessage: Sendable {
    public let messageHash: Data
    public let signature: Data
    /// Whether the account's `isValidSignature` accepted it. Nil if the account isn't deployed yet,
    /// in which case `signature` is ERC-6492 wrapped.
    public let verifiedOnchain: Bool?
}

public enum SmartAccountError: Error, LocalizedError, Equatable {
    case noOwnerKeys
    case unknownCredential
    case signatureInvalid

    public var errorDescription: String? {
        switch self {
        case .noOwnerKeys: return "This wallet has no keys that can sign on this network"
        case .unknownCredential: return "That key isn't an owner of this wallet"
        case .signatureInvalid: return "The key's signature didn't verify against its registered public key"
        }
    }
}

/// A Coinbase Smart Wallet controlled by P-256 (WebAuthn) owner keys.
public struct SmartAccount: Sendable {
    public let address: Address
    /// The owners the account was created with. They determine the address and the `initCode`.
    public let initialOwners: [Data]
    public let chain: Chain
    public let client: EthereumClient
    public let bundler: BundlerClient
    public let paymaster: PaymasterClient?

    public init(address: Address, initialOwners: [Data], chain: Chain, bundlerURL: URL? = nil, paymasterURL: URL? = nil) {
        self.address = address
        self.initialOwners = initialOwners
        self.chain = chain
        self.client = EthereumClient(url: chain.rpcURL)
        self.bundler = BundlerClient(url: bundlerURL ?? chain.defaultBundlerURL)
        self.paymaster = paymasterURL.map { PaymasterClient(url: $0) }
    }

    public func isDeployed() async throws -> Bool {
        try await client.isDeployed(address)
    }

    public func balance() async throws -> UInt256 {
        try await client.balance(of: address)
    }

    /// `EntryPoint.getNonce(sender, 0)`.
    public func nonce() async throws -> UInt256 {
        let data = ABI.encodeCall("getNonce(address,uint192)", [.address(address), .uint(0)])
        return try ABIDecoder(try await client.call(to: CoinbaseSmartWallet.entryPoint, data: data)).uint(at: 0)
    }

    /// Owner index a newly added key will get.
    public func nextOwnerIndex() async throws -> Int {
        try await isDeployed()
            ? try await CoinbaseSmartWallet.nextOwnerIndex(account: address, client: client)
            : initialOwners.count
    }

    public func gasPrice() async throws -> GasPrice {
        if let price = await bundler.pimlicoGasPrice() { return price }
        async let baseFee = client.baseFeePerGas()
        async let priority = client.maxPriorityFeePerGas()
        let tip = try await priority
        return GasPrice(maxFeePerGas: try await baseFee * 2 + tip, maxPriorityFeePerGas: tip)
    }

    /// Builds a user operation for `calls`, estimates gas and attaches paymaster data if configured.
    public func prepare(calls: [CoinbaseSmartWallet.Call], signingOwnerIndex: Int) async throws -> PreparedOperation {
        async let deployedTask = isDeployed()
        async let nonceTask = nonce()
        async let priceTask = gasPrice()
        let deployed = try await deployedTask
        let price = try await priceTask

        var op = UserOperation(
            sender: address,
            nonce: try await nonceTask,
            initCode: deployed ? Data() : CoinbaseSmartWallet.initCode(owners: initialOwners),
            callData: CoinbaseSmartWallet.callData(for: calls),
            maxFeePerGas: price.maxFeePerGas,
            maxPriorityFeePerGas: price.maxPriorityFeePerGas,
            signature: CoinbaseSmartWallet.dummySignature(ownerIndex: signingOwnerIndex)
        )

        if let paymaster {
            op.paymasterAndData = try await paymaster.stubData(for: op, chainID: chain.id)
        }

        // Without a paymaster, an unfunded account fails estimation with "AA21 didn't pay prefund". Estimating
        // against a temporary balance lets us show the fee first and check the real balance afterwards.
        let estimate = try await bundler.estimateGas(
            op,
            stateOverride: paymaster == nil ? Self.fundedOverride(for: address) : nil
        )
        op.preVerificationGas = estimate.preVerificationGas * 11 / 10
        op.verificationGasLimit = estimate.verificationGasLimit + UInt256(chain.verificationGasBuffer)
        op.callGasLimit = estimate.callGasLimit * 12 / 10

        if let paymaster {
            op.paymasterAndData = try await paymaster.data(for: op, chainID: chain.id)
        }
        op.signature = Data()

        let value = calls.reduce(UInt256.zero) { $0 + $1.value }
        let sponsored = !op.paymasterAndData.isEmpty
        return PreparedOperation(
            userOperation: op,
            hash: op.hash(entryPoint: CoinbaseSmartWallet.entryPoint, chainID: chain.id),
            isSponsored: sponsored,
            deploysAccount: !deployed,
            requiredBalance: (sponsored ? 0 : op.maxCost) + value
        )
    }

    static func fundedOverride(for address: Address) -> JSONValue {
        [address.checksummed: ["balance": .string(UInt256(decimal: "1000000000000000000000")!.hexQuantity)]]
    }

    /// Asks the signer for an assertion over the operation hash and attaches it.
    public func sign(_ prepared: PreparedOperation, signer: WebAuthnSigner, owners: [OwnerKey]) async throws -> UserOperation {
        var op = prepared.userOperation
        op.signature = try await signature(for: prepared.hash, signer: signer, owners: owners)
        return op
    }

    public func submit(_ op: UserOperation) async throws -> String {
        try await bundler.send(op)
    }

    /// Signs an EIP-191 message as the smart account (ERC-1271), e.g. for Sign-In with Ethereum.
    public func signPersonalMessage(_ message: Data, signer: WebAuthnSigner, owners: [OwnerKey]) async throws -> SignedMessage {
        let hash = personalMessageHash(message)
        let safeHash = CoinbaseSmartWallet.replaySafeHash(hash, account: address, chainID: chain.id)
        let wrapped = try await signature(for: safeHash, signer: signer, owners: owners)
        if try await isDeployed() {
            let valid = try await CoinbaseSmartWallet.isValidSignature(account: address, hash: hash, signature: wrapped, client: client)
            return SignedMessage(messageHash: hash, signature: wrapped, verifiedOnchain: valid)
        }
        return SignedMessage(
            messageHash: hash,
            signature: CoinbaseSmartWallet.erc6492Wrap(signature: wrapped, owners: initialOwners),
            verifiedOnchain: nil
        )
    }

    /// Produces a `SignatureWrapper` for `challenge` from whichever owner key the user presents.
    public func signature(for challenge: Data, signer: WebAuthnSigner, owners: [OwnerKey]) async throws -> Data {
        guard !owners.isEmpty else { throw SmartAccountError.noOwnerKeys }
        let assertion = try await signer.assert(challenge: challenge, allowedCredentialIDs: owners.map(\.credentialID))
        guard let owner = owners.first(where: { $0.credentialID == assertion.credentialID }) else {
            throw SmartAccountError.unknownCredential
        }
        // Catch a wrong key or malformed response here rather than as an opaque onchain validation failure.
        guard assertion.verify(publicKey: owner.publicKey) else { throw SmartAccountError.signatureInvalid }
        let auth = try CoinbaseSmartWallet.encodeWebAuthnAuth(assertion, challenge: challenge)
        return CoinbaseSmartWallet.wrapSignature(ownerIndex: owner.ownerIndex, signatureData: auth)
    }
}
