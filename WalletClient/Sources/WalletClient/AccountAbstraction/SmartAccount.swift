import Foundation
import P256WalletCore

/// A user operation with gas and paymaster data filled in, plus the core's review of it. Ready to sign.
public struct PreparedOperation: Sendable {
    public let userOperation: UserOperation
    /// What the review screen shows, decoded by the core from `userOperation` itself. `review.hash` is the challenge.
    public let review: OperationReview
}

public struct MessageSignature: Sendable {
    public let messageHash: String
    public let signature: String
    /// Whether the account's `isValidSignature` accepted it. Nil if the account isn't deployed yet, in which case
    /// `signature` is ERC-6492 wrapped.
    public let verifiedOnchain: Bool?
}

/// The network side of a Coinbase Smart Wallet: fetches what the core needs (nonce, deployment, gas) and submits
/// what it signs. What gets signed is decided by the core.
public struct SmartAccount: Sendable {
    public let address: String
    /// The owners the account was created with (owner bytes, hex, in order). They determine the address.
    public let initialOwners: [String]
    public let chain: Chain
    public let client: EthereumClient
    public let bundler: BundlerClient
    public let paymaster: PaymasterClient?

    public init(address: String, initialOwners: [String], chain: Chain, bundlerURL: URL? = nil, paymasterURL: URL? = nil) {
        self.address = address
        self.initialOwners = initialOwners
        self.chain = chain
        self.client = EthereumClient(url: chain.rpc)
        self.bundler = BundlerClient(url: bundlerURL ?? chain.defaultBundler)
        self.paymaster = paymasterURL.map { PaymasterClient(url: $0) }
    }

    public func isDeployed() async throws -> Bool {
        try await client.isDeployed(address)
    }

    public func balance() async throws -> String {
        try await client.balance(of: address)
    }

    /// `EntryPoint.getNonce(sender, 0)`.
    public func nonce() async throws -> String {
        let call = try encodeFunctionCall(signature: "getNonce(address,uint192)", arguments: [address, "0"])
        return try abiDecode(types: ["uint256"], data: try await client.call(to: entryPointAddress(), data: call.data))[0]
    }

    /// Owner index a newly added key will get.
    public func nextOwnerIndex() async throws -> UInt32 {
        guard try await isDeployed() else { return UInt32(initialOwners.count) }
        let call = try encodeFunctionCall(signature: "nextOwnerIndex()", arguments: [])
        let value = try abiDecode(types: ["uint256"], data: try await client.call(to: address, data: call.data))[0]
        guard let index = UInt32(value.dropFirst(2), radix: 16) else {
            throw TransportError.malformedResponse("nextOwnerIndex")
        }
        return index
    }

    public func gasPrice() async throws -> GasPrice {
        if let price = await bundler.pimlicoGasPrice() { return price }
        async let baseFee = client.baseFeePerGas()
        async let tip = client.maxPriorityFeePerGas()
        return try fallbackGasPrice(baseFeePerGas: try await baseFee, maxPriorityFeePerGas: try await tip)
    }

    /// Builds a user operation for `calls`, estimates gas, attaches paymaster data if configured, and has the core
    /// review it. `tokens` and `functionSignatures` help the review name tokens and functions.
    public func prepare(
        calls: [Call],
        signingOwnerIndex: UInt32,
        tokens: [Token] = [],
        functionSignatures: [String] = []
    ) async throws -> PreparedOperation {
        async let deployedTask = isDeployed()
        async let nonceTask = nonce()
        async let priceTask = gasPrice()
        var op = try buildUserOperation(
            sender: address,
            nonce: try await nonceTask,
            deployed: try await deployedTask,
            initialOwners: initialOwners,
            calls: calls,
            gasPrice: try await priceTask,
            signingOwnerIndex: signingOwnerIndex
        )

        if let paymaster {
            op.paymasterAndData = try await paymaster.stubData(for: op, chainID: chain.id)
        }
        // Without a paymaster, an unfunded account fails estimation with "AA21 didn't pay prefund". Estimating
        // against a temporary balance lets the review show the fee first and check the real balance afterwards.
        let estimate = try await bundler.estimateGas(
            op,
            stateOverride: paymaster == nil ? Self.fundedOverride(for: address) : nil
        )
        op = try applyGasEstimate(op: op, estimate: estimate, verificationGasBuffer: chain.verificationGasBuffer)
        if let paymaster {
            op.paymasterAndData = try await paymaster.data(for: op, chainID: chain.id)
        }
        op.signature = "0x"

        let review = try reviewUserOperation(op: op, chainId: chain.id, tokens: tokens, functionSignatures: functionSignatures)
        return PreparedOperation(userOperation: op, review: review)
    }

    /// 1000 ETH, only ever used in simulation.
    static func fundedOverride(for address: String) -> JSONValue {
        [address: ["balance": "0x3635c9adc5dea00000"]]
    }

    /// Asks the signer for an assertion over the operation's hash; the core checks it and attaches the signature.
    public func sign(_ prepared: PreparedOperation, signer: WebAuthnSigner, owners: [OwnerKey]) async throws -> UserOperation {
        let assertion = try await signer.assert(
            challenge: try Data(hex: prepared.review.hash),
            allowedCredentialIDs: try owners.map { try Data(hex: $0.credentialId) },
            requireUserVerification: owners.contains { $0.requireUserVerification }
        )
        return try signUserOperation(
            op: prepared.userOperation,
            chainId: chain.id,
            assertion: assertion,
            owners: owners,
            initialOwners: initialOwners
        )
    }

    public func submit(_ op: UserOperation) async throws -> String {
        try await bundler.send(op)
    }

    /// Signs an EIP-191 message as the smart account (ERC-1271), e.g. for Sign-In with Ethereum.
    public func signPersonalMessage(_ message: String, signer: WebAuthnSigner, owners: [OwnerKey]) async throws -> MessageSignature {
        let challenge = try messageChallenge(message: message, account: address, chainId: chain.id)
        let assertion = try await signer.assert(
            challenge: try Data(hex: challenge.challenge),
            allowedCredentialIDs: try owners.map { try Data(hex: $0.credentialId) },
            requireUserVerification: owners.contains { $0.requireUserVerification }
        )
        let deployed = try await isDeployed()
        let signed = try signMessage(
            message: message,
            account: address,
            chainId: chain.id,
            assertion: assertion,
            owners: owners,
            deployed: deployed,
            initialOwners: initialOwners
        )
        let verified = deployed ? try await isValidSignature(hash: signed.messageHash, signature: signed.signature) : nil
        return MessageSignature(messageHash: signed.messageHash, signature: signed.signature, verifiedOnchain: verified)
    }

    public func isValidSignature(hash: String, signature: String) async throws -> Bool {
        let call = try encodeFunctionCall(signature: "isValidSignature(bytes32,bytes)", arguments: [hash, signature])
        do {
            return isErc1271Success(result: try await client.call(to: address, data: call.data))
        } catch is RPCError {
            return false
        }
    }
}
