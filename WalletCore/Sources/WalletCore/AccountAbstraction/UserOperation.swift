import Foundation

/// ERC-4337 EntryPoint v0.6 user operation (the version Coinbase Smart Wallet v1 targets).
public struct UserOperation: Sendable, Equatable {
    public static let entryPointV06 = Address("0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789")!

    public var sender: Address
    public var nonce: UInt256
    public var initCode: Data
    public var callData: Data
    public var callGasLimit: UInt256
    public var verificationGasLimit: UInt256
    public var preVerificationGas: UInt256
    public var maxFeePerGas: UInt256
    public var maxPriorityFeePerGas: UInt256
    public var paymasterAndData: Data
    public var signature: Data

    public init(
        sender: Address,
        nonce: UInt256,
        initCode: Data = Data(),
        callData: Data,
        callGasLimit: UInt256 = 0,
        verificationGasLimit: UInt256 = 0,
        preVerificationGas: UInt256 = 0,
        maxFeePerGas: UInt256 = 0,
        maxPriorityFeePerGas: UInt256 = 0,
        paymasterAndData: Data = Data(),
        signature: Data = Data()
    ) {
        self.sender = sender
        self.nonce = nonce
        self.initCode = initCode
        self.callData = callData
        self.callGasLimit = callGasLimit
        self.verificationGasLimit = verificationGasLimit
        self.preVerificationGas = preVerificationGas
        self.maxFeePerGas = maxFeePerGas
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.paymasterAndData = paymasterAndData
        self.signature = signature
    }

    /// `EntryPoint.getUserOpHash`: the 32 bytes the account owner signs.
    public func hash(entryPoint: Address = UserOperation.entryPointV06, chainID: UInt64) -> Data {
        let packed = ABI.encode([
            .address(sender),
            .uint(nonce),
            .fixedBytes(Keccak256.hash(initCode)),
            .fixedBytes(Keccak256.hash(callData)),
            .uint(callGasLimit),
            .uint(verificationGasLimit),
            .uint(preVerificationGas),
            .uint(maxFeePerGas),
            .uint(maxPriorityFeePerGas),
            .fixedBytes(Keccak256.hash(paymasterAndData)),
        ])
        return Keccak256.hash(ABI.encode([
            .fixedBytes(Keccak256.hash(packed)),
            .address(entryPoint),
            .uint(UInt256(chainID)),
        ]))
    }

    /// Upper bound on what this operation can cost the payer, in wei.
    public var maxCost: UInt256 {
        (callGasLimit + verificationGasLimit + preVerificationGas) * maxFeePerGas
    }

    /// The struct as an ABI tuple, for calling EntryPoint view functions.
    public var abiTuple: ABIValue {
        .tuple([
            .address(sender), .uint(nonce), .bytes(initCode), .bytes(callData),
            .uint(callGasLimit), .uint(verificationGasLimit), .uint(preVerificationGas),
            .uint(maxFeePerGas), .uint(maxPriorityFeePerGas), .bytes(paymasterAndData), .bytes(signature),
        ])
    }

    /// JSON shape expected by bundlers (`eth_sendUserOperation` et al).
    public var json: JSONValue {
        [
            "sender": .string(sender.checksummed),
            "nonce": .string(nonce.hexQuantity),
            "initCode": .string(initCode.hexPrefixed),
            "callData": .string(callData.hexPrefixed),
            "callGasLimit": .string(callGasLimit.hexQuantity),
            "verificationGasLimit": .string(verificationGasLimit.hexQuantity),
            "preVerificationGas": .string(preVerificationGas.hexQuantity),
            "maxFeePerGas": .string(maxFeePerGas.hexQuantity),
            "maxPriorityFeePerGas": .string(maxPriorityFeePerGas.hexQuantity),
            "paymasterAndData": .string(paymasterAndData.hexPrefixed),
            "signature": .string(signature.hexPrefixed),
        ]
    }
}
