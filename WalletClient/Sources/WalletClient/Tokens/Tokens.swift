import Foundation
import P256WalletCore

public struct TokenBalance: Sendable, Hashable, Identifiable {
    public let token: Token
    /// Base units, as a hex quantity.
    public let balance: String

    public var id: String { token.address }
    public var formatted: String {
        (try? formatUnits(quantity: balance, decimals: token.decimals, maxFractionDigits: 6)) ?? balance
    }

    public init(token: Token, balance: String) {
        self.token = token
        self.balance = balance
    }
}

/// Lists ERC-20 balances for an address.
public protocol TokenBalanceProvider: Sendable {
    func balances(of owner: String) async throws -> [TokenBalance]
}

/// Uses Blockscout's v2 API, which indexes every token transfer and needs no API key.
public struct BlockscoutTokenProvider: TokenBalanceProvider {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func balances(of owner: String) async throws -> [TokenBalance] {
        let url = baseURL.appending(path: "api/v2/addresses/\(owner)/token-balances")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Blockscout returns 404 for addresses it has never seen, which for us means "no tokens yet".
        if status == 404 { return [] }
        guard (200..<300).contains(status) else {
            throw TransportError.http(status, String(decoding: data, as: UTF8.self))
        }
        guard case .array(let items) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw TransportError.malformedResponse("token-balances is not an array")
        }
        return items.compactMap { item -> TokenBalance? in
            guard let tokenJSON = item["token"], tokenJSON["type"]?.stringValue == "ERC-20",
                  let addressText = tokenJSON["address_hash"]?.stringValue ?? tokenJSON["address"]?.stringValue,
                  let address = try? checksumAddress(address: addressText.lowercased()),
                  let decimalsText = tokenJSON["decimals"]?.quantityValue,
                  let decimals = UInt8(decimalsText.dropFirst(2), radix: 16),
                  let balance = item["value"]?.quantityValue, !balance.isZeroQuantity
            else { return nil }
            if let reputation = tokenJSON["reputation"]?.stringValue, reputation != "ok" { return nil }
            let token = Token(
                address: address,
                symbol: tokenJSON["symbol"]?.stringValue ?? "???",
                name: tokenJSON["name"]?.stringValue ?? "Unknown token",
                decimals: decimals
            )
            return TokenBalance(token: token, balance: balance)
        }
    }
}

/// Fallback: `balanceOf` for a fixed list of tokens over plain RPC.
public struct KnownTokenProvider: TokenBalanceProvider {
    public let client: EthereumClient
    public let tokens: [Token]

    public init(client: EthereumClient, tokens: [Token]) {
        self.client = client
        self.tokens = tokens
    }

    public func balances(of owner: String) async throws -> [TokenBalance] {
        let call = try encodeFunctionCall(signature: "balanceOf(address)", arguments: [owner])
        return try await withThrowingTaskGroup(of: TokenBalance?.self) { group in
            for token in tokens {
                group.addTask {
                    let result = try await client.call(to: token.address, data: call.data)
                    let balance = try abiDecode(types: ["uint256"], data: result)[0]
                    return balance.isZeroQuantity ? nil : TokenBalance(token: token, balance: balance)
                }
            }
            var balances = [TokenBalance]()
            for try await balance in group {
                if let balance { balances.append(balance) }
            }
            return balances
        }
    }
}

/// Tries the indexer first and falls back to known tokens.
public struct CompositeTokenProvider: TokenBalanceProvider {
    public let primary: TokenBalanceProvider?
    public let fallback: TokenBalanceProvider

    public init(primary: TokenBalanceProvider?, fallback: TokenBalanceProvider) {
        self.primary = primary
        self.fallback = fallback
    }

    public func balances(of owner: String) async throws -> [TokenBalance] {
        var balances: [TokenBalance]
        if let primary, let indexed = try? await primary.balances(of: owner) {
            balances = indexed
        } else {
            balances = try await fallback.balances(of: owner)
        }
        return balances.sorted { lhs, rhs in
            lhs.token.symbol.localizedCaseInsensitiveCompare(rhs.token.symbol) == .orderedAscending
        }
    }
}
