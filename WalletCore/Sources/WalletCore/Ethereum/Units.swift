import Foundation

/// Converts between human-readable decimal amounts and integer base units.
public enum Units {
    /// Parses `"1.5"` with 18 decimals into `1500000000000000000`. Returns nil for malformed input,
    /// more fractional digits than `decimals`, or overflow.
    public static func parse(_ text: String, decimals: Int) -> UInt256? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, trimmed != "." else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let whole = parts[0].isEmpty ? "0" : String(parts[0])
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= decimals else { return nil }
        let padded = fraction + String(repeating: "0", count: decimals - fraction.count)
        guard let wholeValue = UInt256(decimal: whole),
              let scale = UInt256.power(10, decimals) else { return nil }
        let fractionValue = padded.isEmpty ? UInt256.zero : UInt256(decimal: padded)
        guard let fractionValue else { return nil }
        let (scaled, o1) = wholeValue.multipliedReportingOverflow(by: scale)
        let (total, o2) = scaled.addingReportingOverflow(fractionValue)
        return o1 || o2 ? nil : total
    }

    /// Formats base units for display, truncating (never rounding up) to `maxFractionDigits`.
    public static func format(_ value: UInt256, decimals: Int, maxFractionDigits: Int = 6) -> String {
        guard decimals > 0, let scale = UInt256.power(10, decimals) else { return value.decimalString }
        let (whole, remainder) = value.quotientAndRemainder(dividingBy: scale)
        var fraction = remainder.decimalString
        fraction = String(repeating: "0", count: decimals - fraction.count) + fraction
        fraction = String(fraction.prefix(maxFractionDigits))
        while fraction.hasSuffix("0") { fraction.removeLast() }

        let wholeText = groupThousands(whole.decimalString)
        if fraction.isEmpty {
            if whole.isZero && !remainder.isZero {
                return "<0." + String(repeating: "0", count: max(maxFractionDigits - 1, 0)) + "1"
            }
            return wholeText
        }
        return wholeText + "." + fraction
    }

    /// Plain decimal string with full precision and no grouping, suitable for prefilling an input field.
    public static func plain(_ value: UInt256, decimals: Int) -> String {
        guard decimals > 0, let scale = UInt256.power(10, decimals) else { return value.decimalString }
        let (whole, remainder) = value.quotientAndRemainder(dividingBy: scale)
        var fraction = remainder.decimalString
        fraction = String(repeating: "0", count: decimals - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? whole.decimalString : whole.decimalString + "." + fraction
    }

    private static func groupThousands(_ digits: String) -> String {
        var out = ""
        for (index, char) in digits.reversed().enumerated() {
            if index > 0 && index % 3 == 0 { out.append(",") }
            out.append(char)
        }
        return String(out.reversed())
    }
}
