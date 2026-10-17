import SwiftUI
import WalletCore

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
            guard let address = Address(target) else { throw FunctionCallError.invalidArgument(type: "address", value: target) }
            let wei = value.isEmpty ? UInt256.zero : Units.parse(value, decimals: 18)
            guard let wei else { throw FunctionCallError.invalidArgument(type: "ETH value", value: value) }
            let data: Data
            var details: [TransactionRequest.Detail] = [.init(label: "Contract", value: address.short, monospaced: true)]
            switch mode {
            case .function:
                let args = arguments.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                data = try FunctionCall.encode(signature: signature, arguments: args)
                details.append(.init(label: "Function", value: try FunctionCall.parse(signature).name, monospaced: true))
            case .raw:
                data = calldata.isEmpty ? Data() : try Data(hex: calldata)
                details.append(data.isEmpty
                    ? .init(label: "Selector", value: "None (plain transfer)")
                    : .init(label: "Selector", value: data.prefix(4).hexPrefixed, monospaced: true))
            }
            if !wei.isZero {
                details.append(.init(label: "Value", value: "\(Units.format(wei, decimals: 18, maxFractionDigits: 18)) ETH"))
            }
            details.append(.init(label: "Calldata", value: "\(data.count) bytes"))
            request = TransactionRequest(title: "Contract call", details: details, calls: [.init(target: address, value: wei, data: data)])
        } catch {
            self.error = error.localizedDescription
        }
    }
}
