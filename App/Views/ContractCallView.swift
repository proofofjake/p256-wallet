import SwiftUI
import WalletClient

/// Arbitrary contract interaction executed by the smart account (its `execute` function).
struct ContractCallView: View {
    private enum Mode: String, CaseIterable {
        case function = "Function"
        case raw = "Raw calldata"
    }

    @State private var target = ""
    @State private var value = ""
    @State private var mode = Mode.function
    @State private var signature = ""
    @State private var arguments = ""
    @State private var calldata = ""
    @State private var error: String?
    @State private var request: TransactionRequest?

    var body: some View {
        Form {
            Section("Contract") {
                TextField("0x…", text: $target)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                TextField("0", text: $value).keyboardType(.decimalPad)
            } header: {
                Text("Value (ETH)")
            }
            Section {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch mode {
                case .function:
                    TextField("transfer(address,uint256)", text: $signature)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Arguments, one per line", text: $arguments, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...8)
                case .raw:
                    TextField("0x…", text: $calldata, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...8)
                }
            } header: {
                Text("Call")
            } footer: {
                Text(mode == .function
                     ? "Supports address, bool, uintN, bytesN, bytes and string. Amounts are in base units (no decimals). Use raw calldata for arrays and tuples."
                     : "Hex-encoded calldata including the 4-byte selector. Leave empty for a plain ETH transfer.")
            }
            if let error {
                Section { ErrorText(message: error) }
            }
        }
        .navigationTitle("Contract call")
        .safeAreaInset(edge: .bottom) {
            Button("Review") { review() }
                .primaryAction()
                .disabled(target.isEmpty)
                .padding()
        }
        .sheet(item: $request) { TransactionSheet(request: $0) }
    }

    private func review() {
        error = nil
        do {
            let address = try checksumAddress(address: target.trimmingCharacters(in: .whitespacesAndNewlines))
            let wei = value.isEmpty ? "0x0" : try parseUnits(text: value, decimals: 18)
            let data: String
            var signatures: [String] = []
            switch mode {
            case .function:
                let args = arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                data = try encodeFunctionCall(signature: signature, arguments: args).data
                signatures = [signature]
            case .raw:
                let trimmed = calldata.trimmingCharacters(in: .whitespacesAndNewlines)
                data = trimmed.isEmpty ? "0x" : try Data(hex: trimmed).hexPrefixed
            }
            request = TransactionRequest(
                title: "Contract call",
                calls: [Call(target: address, value: wei, data: data)],
                functionSignatures: signatures
            )
        } catch {
            self.error = error.localizedDescription
        }
    }
}
