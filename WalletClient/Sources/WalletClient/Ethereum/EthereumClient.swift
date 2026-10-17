import Foundation

/// Typed wrappers over the standard `eth_*` methods this wallet uses. Addresses and data are `0x` hex strings and
/// numbers are hex quantities, the formats the core takes.
public struct EthereumClient: Sendable {
    public let rpc: RPCClient

    public init(rpc: RPCClient) {
        self.rpc = rpc
    }

    public init(url: URL) {
        self.init(rpc: RPCClient(url: url))
    }

    public func chainID() async throws -> UInt64 {
        guard let value = try await rpc.send("eth_chainId").quantityValue, let id = UInt64(value.dropFirst(2), radix: 16) else {
            throw TransportError.malformedResponse("eth_chainId")
        }
        return id
    }

    public func balance(of address: String) async throws -> String {
        try quantity(try await rpc.send("eth_getBalance", [.string(address), "latest"]), "eth_getBalance")
    }

    public func code(at address: String) async throws -> String {
        try hex(try await rpc.send("eth_getCode", [.string(address), "latest"]), "eth_getCode")
    }

    public func isDeployed(_ address: String) async throws -> Bool {
        try await code(at: address) != "0x"
    }

    /// `eth_call`. Reverts surface as `RPCError` with `revertData` set.
    public func call(to: String, data callData: String, from: String? = nil, stateOverride: JSONValue? = nil) async throws -> String {
        var tx: [String: JSONValue] = ["to": .string(to), "data": .string(callData)]
        if let from { tx["from"] = .string(from) }
        var params: [JSONValue] = [.object(tx), "latest"]
        if let stateOverride { params.append(stateOverride) }
        return try hex(try await rpc.send("eth_call", params), "eth_call")
    }

    public func baseFeePerGas() async throws -> String {
        let block = try await rpc.send("eth_getBlockByNumber", ["latest", false])
        guard let fee = block["baseFeePerGas"]?.quantityValue else {
            throw TransportError.malformedResponse("block has no baseFeePerGas")
        }
        return fee
    }

    public func maxPriorityFeePerGas() async throws -> String {
        try quantity(try await rpc.send("eth_maxPriorityFeePerGas"), "eth_maxPriorityFeePerGas")
    }

    private func quantity(_ value: JSONValue, _ method: String) throws -> String {
        guard let number = value.quantityValue else { throw TransportError.malformedResponse(method) }
        return number
    }

    private func hex(_ value: JSONValue, _ method: String) throws -> String {
        guard let bytes = value.hexValue else { throw TransportError.malformedResponse(method) }
        return bytes.lowercased()
    }
}
