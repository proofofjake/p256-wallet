import SwiftUI
import UIKit
import WalletCore

struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct Asset: Hashable, Identifiable {
        let id: String
        let symbol: String
        let decimals: Int
        let balance: UInt256
        /// Nil for native ETH.
        let token: Address?
    }

    @State private var assetID = "ETH"
    @State private var recipient = ""
    @State private var amount = ""
    @State private var request: TransactionRequest?

    private var assets: [Asset] {
        [Asset(id: "ETH", symbol: "ETH", decimals: 18, balance: model.ethBalance ?? 0, token: nil)]
            + model.tokens.map {
                Asset(id: $0.token.address.checksummed, symbol: $0.token.symbol, decimals: $0.token.decimals, balance: $0.balance, token: $0.token.address)
            }
    }

    private var asset: Asset { assets.first { $0.id == assetID } ?? assets[0] }
    private var recipientAddress: Address? { Address(recipient) }
    private var parsedAmount: UInt256? { Units.parse(amount, decimals: asset.decimals) }

    private var validationMessage: String? {
        if !recipient.isEmpty && recipientAddress == nil { return "Not a valid address (check the checksum)" }
        if recipientAddress == model.wallet?.address { return "That's this wallet's own address" }
        if !amount.isEmpty {
            guard let value = parsedAmount else { return "Invalid amount" }
            if value > asset.balance { return "More than your \(asset.symbol) balance" }
        }
        return nil
    }

    private var canReview: Bool {
        recipientAddress != nil && (parsedAmount.map { !$0.isZero } ?? false) && validationMessage == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Asset") {
                    Picker("Asset", selection: $assetID) {
                        ForEach(assets) { asset in
                            Text("\(asset.symbol) — \(Units.format(asset.balance, decimals: asset.decimals))").tag(asset.id)
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
                            Button("Max") { amount = Units.plain(asset.balance, decimals: asset.decimals) }
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

    private func review() {
        guard let to = recipientAddress, let value = parsedAmount else { return }
        let call: CoinbaseSmartWallet.Call
        if let token = asset.token {
            call = .init(target: token, data: ERC20.transfer(to: to, amount: value))
        } else {
            call = .init(target: to, value: value)
        }
        request = TransactionRequest(
            title: "Send \(asset.symbol)",
            details: [
                .init(label: "Amount", value: "\(Units.format(value, decimals: asset.decimals, maxFractionDigits: asset.decimals)) \(asset.symbol)"),
                .init(label: "To", value: to.short, monospaced: true),
            ],
            calls: [call],
            onConfirmed: { _ in
                amount = ""
                recipient = ""
            }
        )
    }
}
