import Foundation

public enum FunctionCallError: Error, LocalizedError, Equatable {
    case invalidSignature(String)
    case argumentCountMismatch(expected: Int, got: Int)
    case unsupportedType(String)
    case invalidArgument(type: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .invalidSignature(let sig): return "Invalid function signature: \(sig)"
        case .argumentCountMismatch(let expected, let got): return "Expected \(expected) arguments, got \(got)"
        case .unsupportedType(let type): return "Unsupported type \(type). Use raw calldata for arrays and tuples."
        case .invalidArgument(let type, let value): return "Invalid \(type): \(value)"
        }
    }
}

/// Encodes calls written as `transfer(address,uint256)` plus string arguments.
/// Supports address, bool, uintN, bytesN, bytes and string; arrays and tuples need raw calldata.
public enum FunctionCall {
    public static func encode(signature: String, arguments: [String]) throws -> Data {
        let (name, types) = try parse(signature)
        guard types.count == arguments.count else {
            throw FunctionCallError.argumentCountMismatch(expected: types.count, got: arguments.count)
        }
        let values = try zip(types, arguments).map { try value(type: $0, text: $1) }
        return ABI.encodeCall("\(name)(\(types.joined(separator: ",")))", values)
    }

    /// Returns the function name and canonical parameter types. Parameter names are dropped,
    /// so `transfer(address to, uint amount)` becomes `transfer` / `[address, uint256]`.
    public static func parse(_ signature: String) throws -> (name: String, types: [String]) {
        let trimmed = signature.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else {
            throw FunctionCallError.invalidSignature(signature)
        }
        let name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw FunctionCallError.invalidSignature(signature)
        }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        if inner.contains("(") || inner.contains("[") {
            throw FunctionCallError.unsupportedType(String(inner))
        }
        let types = inner.split(separator: ",").map { param -> String in
            let type = param.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            return canonical(type)
        }
        return (name, types)
    }

    private static func canonical(_ type: String) -> String {
        switch type {
        case "uint": return "uint256"
        case "int": return "int256"
        default: return type
        }
    }

    private static func value(type: String, text: String) throws -> ABIValue {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = FunctionCallError.invalidArgument(type: type, value: text)
        switch type {
        case "address":
            guard let address = Address(text) else { throw invalid }
            return .address(address)
        case "bool":
            switch text.lowercased() {
            case "true", "1": return .bool(true)
            case "false", "0": return .bool(false)
            default: throw invalid
            }
        case "string":
            return .string(text)
        case "bytes":
            guard let data = try? Data(hex: text) else { throw invalid }
            return .bytes(data)
        case _ where type.hasPrefix("uint"):
            let bits = Int(type.dropFirst(4)) ?? 0
            guard bits > 0, bits <= 256, bits % 8 == 0 else { throw FunctionCallError.unsupportedType(type) }
            guard let number = UInt256(parsing: text), number.bitWidth <= bits else { throw invalid }
            return .uint(number)
        case _ where type.hasPrefix("bytes"):
            let size = Int(type.dropFirst(5)) ?? 0
            guard size >= 1, size <= 32 else { throw FunctionCallError.unsupportedType(type) }
            guard let data = try? Data(hex: text), data.count == size else { throw invalid }
            return .fixedBytes(data)
        default:
            throw FunctionCallError.unsupportedType(type)
        }
    }
}
