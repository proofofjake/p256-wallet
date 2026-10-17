import Foundation
import P256WalletCore

public struct RPCError: Error, LocalizedError, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    /// The node's message, with any embedded `Error(string)` revert payload decoded to its text.
    public var errorDescription: String? {
        guard let range = message.range(of: "0x08c379a0") else { return message }
        let payload = String(message[range.lowerBound...].prefix { $0.isHexDigit || $0 == "x" })
        guard let reason = decodeRevertReason(data: payload) else { return message }
        return message[..<range.lowerBound].trimmingCharacters(in: .whitespaces) + " " + reason
    }

    /// Revert data from a failed `eth_call`, if the node included it.
    public var revertData: String? {
        data?.hexValue ?? data?["data"]?.hexValue
    }
}

public enum TransportError: Error, LocalizedError, Sendable {
    case http(Int, String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body): return "HTTP \(status): \(body.prefix(200))"
        case .malformedResponse(let detail): return "Malformed response: \(detail)"
        }
    }
}

/// JSON-RPC 2.0 over HTTPS.
public struct RPCClient: Sendable {
    public let url: URL
    private let session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func send(_ method: String, _ params: [JSONValue] = []) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let body: JSONValue = ["jsonrpc": "2.0", "id": .number(1), "method": .string(method), "params": .array(params)]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(JSONValue.self, from: data)

        // Some providers (Pimlico's rate limiter, for one) send `error` as a bare string.
        if let message = decoded?["error"]?.stringValue {
            throw RPCError(code: status, message: message, data: nil)
        }
        if let error = decoded?["error"], !error.isNull {
            let code = error["code"].flatMap { value -> Int? in
                if case .number(let n) = value { return Int(n) }
                return nil
            } ?? 0
            throw RPCError(code: code, message: error["message"]?.stringValue ?? "Unknown RPC error", data: error["data"])
        }
        guard (200..<300).contains(status) else {
            throw TransportError.http(status, String(decoding: data, as: UTF8.self))
        }
        guard let result = decoded?["result"] else {
            throw TransportError.malformedResponse("\(method) returned no result")
        }
        return result
    }
}
