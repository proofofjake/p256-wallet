import SwiftUI
import UIKit
import WalletClient

struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct Asset: Hashable, Identifiable {
        let id: String
        let symbol: String
        let decimals: UInt8
        /// Base units, hex quantity.
        let balance: String
        /// Nil for native ETH.
        let token: String?
    }

    @State private var assetID = "ETH"
    @State private var recipient = ""
    @State private var amount = ""
    @State private var request: TransactionRequest?

    private var assets: [Asset] {
        [Asset(id: "ETH", symbol: "ETH", decimals: 18, balance: model.ethBalance ?? "0x0", token: nil)]
            + model.tokens.map {
                Asset(id: $0.token.address, symbol: $0.token.symbol, decimals: $0.token.decimals, balance: $0.balance, token: $0.token.address)
            }
    }

    private var asset: Asset { assets.first { $0.id == assetID } ?? assets[0] }
    private var recipientAddress: String? { try? checksumAddress(address: recipient.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var parsedAmount: String? { try? parseUnits(text: amount, decimals: asset.decimals) }

    private var validationMessage: String? {
        if !recipient.isEmpty && recipientAddress == nil { return "Not a valid address (check the checksum)" }
        if recipientAddress == model.wallet?.address { return "That's this wallet's own address" }
        if !amount.isEmpty {
            guard let value = parsedAmount else { return "Invalid amount" }
            if (try? compareQuantities(a: value, b: asset.balance)) == 1 { return "More than your \(asset.symbol) balance" }
        }
        return nil
    }

    private var canReview: Bool {
        recipientAddress != nil && (parsedAmount.map { !$0.isZeroQuantity } ?? false) && validationMessage == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Asset") {
                    Picker("Asset", selection: $assetID) {
                        ForEach(assets) { asset in
                            Text("\(asset.symbol) — \(format(asset))").tag(asset.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                Section("To") {
                    HStack {
                        TextField("0x…", text: $recipient)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Paste") { recipient = UIPasteboard.general.string ?? "" }
                            .buttonStyle(.borderless)
                    }
                }
                Section("Amount") {
                    HStack {
                        TextField("0.0", text: $amount)
                            .keyboardType(.decimalPad)
                        Text(asset.symbol).foregroundStyle(.secondary)
                        if asset.token != nil {
                            Button("Max") { amount = (try? formatUnitsPlain(quantity: asset.balance, decimals: asset.decimals)) ?? "" }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let validationMessage {
                    Section { ErrorText(message: validationMessage) }
                }
            }
            .navigationTitle("Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Review") { review() }
                    .primaryAction()
                    .disabled(!canReview)
                    .padding()
            }
            .sheet(item: $request) { request in
                TransactionSheet(request: request)
            }
        }
    }

    private func format(_ asset: Asset) -> String {
        (try? formatUnits(quantity: asset.balance, decimals: asset.decimals, maxFractionDigits: 6)) ?? asset.balance
    }

    private func review() {
        guard let to = recipientAddress, let value = parsedAmount,
              let call = try? transferCall(token: asset.token, to: to, amount: value) else { return }
        request = TransactionRequest(
            title: "Send \(asset.symbol)",
            calls: [call],
            onConfirmed: { _ in
                amount = ""
                recipient = ""
            }
        )
    }
}
