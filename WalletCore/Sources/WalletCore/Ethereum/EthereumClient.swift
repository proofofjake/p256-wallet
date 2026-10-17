import Foundation

/// Typed wrappers over the standard `eth_*` methods this wallet uses.
public struct EthereumClient: Sendable {
    public let rpc: RPCClient

    public init(rpc: RPCClient) {
        self.rpc = rpc
    }

    public init(url: URL) {
        self.init(rpc: RPCClient(url: url))
    }

    public func chainID() async throws -> UInt64 {
        guard let value = try await rpc.send("eth_chainId").uint256Value?.uint64Value else {
            throw TransportError.malformedResponse("eth_chainId")
        }
        return value
    }

    public func balance(of address: Address) async throws -> UInt256 {
        try quantity(try await rpc.send("eth_getBalance", [.string(address.checksummed), "latest"]), "eth_getBalance")
    }

    public func code(at address: Address) async throws -> Data {
        try data(try await rpc.send("eth_getCode", [.string(address.checksummed), "latest"]), "eth_getCode")
    }

    public func isDeployed(_ address: Address) async throws -> Bool {
        !(try await code(at: address)).isEmpty
    }

    /// `eth_call`. Reverts surface as `RPCError` with `revertData` set.
    public func call(to: Address, data callData: Data, from: Address? = nil, stateOverride: JSONValue? = nil) async throws -> Data {
        var tx: [String: JSONValue] = ["to": .string(to.checksummed), "data": .string(callData.hexPrefixed)]
        if let from { tx["from"] = .string(from.checksummed) }
        var params: [JSONValue] = [.object(tx), "latest"]
        if let stateOverride { params.append(stateOverride) }
        return try data(try await rpc.send("eth_call", params), "eth_call")
    }

    public func baseFeePerGas() async throws -> UInt256 {
        let block = try await rpc.send("eth_getBlockByNumber", ["latest", false])
        guard let fee = block["baseFeePerGas"]?.uint256Value else {
            throw TransportError.malformedResponse("block has no baseFeePerGas")
        }
        return fee
    }

    public func maxPriorityFeePerGas() async throws -> UInt256 {
        try quantity(try await rpc.send("eth_maxPriorityFeePerGas"), "eth_maxPriorityFeePerGas")
    }

    private func quantity(_ value: JSONValue, _ method: String) throws -> UInt256 {
        guard let number = value.uint256Value else { throw TransportError.malformedResponse(method) }
        return number
    }

    private func data(_ value: JSONValue, _ method: String) throws -> Data {
        guard let bytes = value.dataValue else { throw TransportError.malformedResponse(method) }
        return bytes
    }
}
