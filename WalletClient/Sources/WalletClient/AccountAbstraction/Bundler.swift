import Foundation
import P256WalletCore

public struct UserOperationReceipt: Sendable, Equatable {
    public let userOpHash: String
    public let success: Bool
    public let reason: String?
    public let actualGasCost: String?
    public let transactionHash: String?
}

/// ERC-4337 bundler JSON-RPC. The core's `UserOperation` encodes to exactly the JSON bundlers expect.
public struct BundlerClient: Sendable {
    public let rpc: RPCClient
    public let entryPoint: String

    public init(url: URL, entryPoint: String = entryPointAddress()) {
        self.rpc = RPCClient(url: url)
        self.entryPoint = entryPoint
    }

    /// `stateOverride` (supported by Pimlico, Alchemy and others) lets estimation run before the account is funded.
    public func estimateGas(_ op: UserOperation, stateOverride: JSONValue? = nil) async throws -> GasEstimate {
        var params: [JSONValue] = [try JSONValue(encoding: op), .string(entryPoint)]
        if let stateOverride { params.append(stateOverride) }
        let result = try await rpc.send("eth_estimateUserOperationGas", params)
        guard let pvg = result["preVerificationGas"]?.quantityValue,
              let vgl = result["verificationGasLimit"]?.quantityValue,
              let cgl = result["callGasLimit"]?.quantityValue else {
            throw TransportError.malformedResponse("eth_estimateUserOperationGas")
        }
        return GasEstimate(preVerificationGas: pvg, verificationGasLimit: vgl, callGasLimit: cgl)
    }

    /// Returns the user operation hash.
    public func send(_ op: UserOperation) async throws -> String {
        let result = try await rpc.send("eth_sendUserOperation", [try JSONValue(encoding: op), .string(entryPoint)])
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
            actualGasCost: result["actualGasCost"]?.quantityValue,
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
              let maxFee = fast["maxFeePerGas"]?.quantityValue,
              let priority = fast["maxPriorityFeePerGas"]?.quantityValue else { return nil }
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
    public let entryPoint: String
    public let context: JSONValue

    public init(url: URL, entryPoint: String = entryPointAddress(), context: JSONValue = .object([:])) {
        self.rpc = RPCClient(url: url)
        self.entryPoint = entryPoint
        self.context = context
    }

    /// Placeholder `paymasterAndData` for gas estimation.
    public func stubData(for op: UserOperation, chainID: UInt64) async throws -> String {
        try await paymasterAndData("pm_getPaymasterStubData", op, chainID)
    }

    /// Final, signed `paymasterAndData`. Call after gas limits are set; they are covered by the sponsorship.
    public func data(for op: UserOperation, chainID: UInt64) async throws -> String {
        try await paymasterAndData("pm_getPaymasterData", op, chainID)
    }

    private func paymasterAndData(_ method: String, _ op: UserOperation, _ chainID: UInt64) async throws -> String {
        let result = try await rpc.send(method, [
            try JSONValue(encoding: op), .string(entryPoint), .string("0x" + String(chainID, radix: 16)), context,
        ])
        guard let data = result["paymasterAndData"]?.hexValue else { throw TransportError.malformedResponse(method) }
        return data
    }
}
