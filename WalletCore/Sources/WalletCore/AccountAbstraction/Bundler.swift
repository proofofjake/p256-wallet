import Foundation

public struct GasEstimate: Sendable, Equatable {
    public let preVerificationGas: UInt256
    public let verificationGasLimit: UInt256
    public let callGasLimit: UInt256
}

public struct GasPrice: Sendable, Equatable {
    public let maxFeePerGas: UInt256
    public let maxPriorityFeePerGas: UInt256
}

public struct UserOperationReceipt: Sendable, Equatable {
    public let userOpHash: String
    public let success: Bool
    public let reason: String?
    public let actualGasCost: UInt256?
    public let transactionHash: String?
}

/// ERC-4337 bundler JSON-RPC.
public struct BundlerClient: Sendable {
    public let rpc: RPCClient
    public let entryPoint: Address

    public init(url: URL, entryPoint: Address = UserOperation.entryPointV06) {
        self.rpc = RPCClient(url: url)
        self.entryPoint = entryPoint
    }

    /// `stateOverride` (supported by Pimlico, Alchemy and others) lets estimation run before the account is funded.
    public func estimateGas(_ op: UserOperation, stateOverride: JSONValue? = nil) async throws -> GasEstimate {
        var params: [JSONValue] = [op.json, .string(entryPoint.checksummed)]
        if let stateOverride { params.append(stateOverride) }
        let result = try await rpc.send("eth_estimateUserOperationGas", params)
        guard let pvg = result["preVerificationGas"]?.uint256Value,
              let vgl = result["verificationGasLimit"]?.uint256Value,
              let cgl = result["callGasLimit"]?.uint256Value else {
            throw TransportError.malformedResponse("eth_estimateUserOperationGas")
        }
        return GasEstimate(preVerificationGas: pvg, verificationGasLimit: vgl, callGasLimit: cgl)
    }

    /// Returns the user operation hash.
    public func send(_ op: UserOperation) async throws -> String {
        let result = try await rpc.send("eth_sendUserOperation", [op.json, .string(entryPoint.checksummed)])
        guard let hash = result.stringValue else { throw TransportError.malformedResponse("eth_sendUserOperation") }
        return hash
    }

    public func receipt(_ userOpHash: String) async throws -> UserOperationReceipt? {
        let result = try await rpc.send("eth_getUserOperationReceipt", [.string(userOpHash)])
        if result.isNull { return nil }
        return UserOperationReceipt(
            userOpHash: userOpHash,
            success: result["success"]?.boolValue ?? false,
            reason: result["reason"]?.stringValue,
            actualGasCost: result["actualGasCost"]?.uint256Value,
            transactionHash: result["receipt"]?["transactionHash"]?.stringValue
        )
    }

    public func waitForReceipt(_ userOpHash: String, timeout: Duration = .seconds(90)) async throws -> UserOperationReceipt {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if let receipt = try await receipt(userOpHash) { return receipt }
            try await Task.sleep(for: .seconds(2))
        }
        throw BundlerError.timedOut(userOpHash)
    }

    /// Pimlico's recommended fees. Returns nil if the bundler doesn't support the method.
    public func pimlicoGasPrice() async -> GasPrice? {
        guard let result = try? await rpc.send("pimlico_getUserOperationGasPrice"),
              let fast = result["fast"],
              let maxFee = fast["maxFeePerGas"]?.uint256Value,
              let priority = fast["maxPriorityFeePerGas"]?.uint256Value else { return nil }
        return GasPrice(maxFeePerGas: maxFee, maxPriorityFeePerGas: priority)
    }
}

public enum BundlerError: Error, LocalizedError, Equatable {
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut(let hash): return "Timed out waiting for user operation \(hash)"
        }
    }
}

/// ERC-7677 paymaster web service (`pm_getPaymasterStubData` / `pm_getPaymasterData`), as offered by
/// Coinbase Developer Platform, Pimlico, Alchemy and others.
public struct PaymasterClient: Sendable {
    public let rpc: RPCClient
    public let entryPoint: Address
    public let context: JSONValue

    public init(url: URL, entryPoint: Address = UserOperation.entryPointV06, context: JSONValue = .object([:])) {
        self.rpc = RPCClient(url: url)
        self.entryPoint = entryPoint
        self.context = context
    }

    /// Placeholder `paymasterAndData` for gas estimation.
    public func stubData(for op: UserOperation, chainID: UInt64) async throws -> Data {
        try await paymasterAndData("pm_getPaymasterStubData", op, chainID)
    }

    /// Final, signed `paymasterAndData`. Call after gas limits are set; they are covered by the sponsorship.
    public func data(for op: UserOperation, chainID: UInt64) async throws -> Data {
        try await paymasterAndData("pm_getPaymasterData", op, chainID)
    }

    private func paymasterAndData(_ method: String, _ op: UserOperation, _ chainID: UInt64) async throws -> Data {
        let result = try await rpc.send(method, [
            op.json, .string(entryPoint.checksummed), .string(UInt256(chainID).hexQuantity), context,
        ])
        guard let data = result["paymasterAndData"]?.dataValue else { throw TransportError.malformedResponse(method) }
        return data
    }
}
