import SwiftUI
import WalletCore

/// What a screen wants executed, plus how to describe it for review.
struct TransactionRequest: Identifiable {
    struct Detail: Hashable {
        let label: String
        let value: String
        var monospaced = false
    }

    let id = UUID()
    let title: String
    let details: [Detail]
    let calls: [CoinbaseSmartWallet.Call]
    var onConfirmed: (@MainActor (UserOperationReceipt) -> Void)?
}

/// Review → sign with the security key → submit to the bundler → wait for inclusion.
struct TransactionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: TransactionRequest

    private enum Phase {
        case preparing
        case ready(PreparedOperation)
        case signing
        case submitting
        case pending(String)
        case confirmed(UserOperationReceipt)
        case failed(String)
    }

    @State private var phase: Phase = .preparing
    @State private var prepared: PreparedOperation?
    @State private var balance: UInt256 = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow(label: "Network", value: model.chain.name)
                    ForEach(request.details, id: \.self) { detail in
                        DetailRow(label: detail.label, value: detail.value, monospaced: detail.monospaced)
                    }
                }
                feeSection
                statusSection
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isBusy { Button(isFinished ? "Done" : "Cancel") { dismiss() } }
                }
            }
            .safeAreaInset(edge: .bottom) { actionButton.padding() }
            .interactiveDismissDisabled(isBusy)
            .task { await prepare() }
        }
    }

    @ViewBuilder
    private var feeSection: some View {
        if let prepared {
            Section("Network fee") {
                if prepared.isSponsored {
                    Label("Sponsored by paymaster", systemImage: "gift")
                } else {
                    DetailRow(label: "Up to", value: "\(Units.format(prepared.maxGasCost, decimals: 18, maxFractionDigits: 8)) ETH")
                }
                if prepared.deploysAccount {
                    Label("Includes one-time account deployment", systemImage: "shippingbox")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch phase {
        case .preparing:
            Section { HStack { ProgressView(); Text("Estimating…").foregroundStyle(.secondary) } }
        case .ready(let prepared):
            if balance < prepared.requiredBalance {
                Section {
                    ErrorText(message: "Not enough ETH. This needs up to \(Units.format(prepared.requiredBalance, decimals: 18, maxFractionDigits: 8)) ETH including gas; the wallet holds \(Units.format(balance, decimals: 18, maxFractionDigits: 8)).")
                }
            }
        case .signing:
            Section {
                HStack {
                    ProgressView()
                    Text(model.signer.usesSecurityKey ? "Waiting for your security key…" : "Signing…").foregroundStyle(.secondary)
                }
            }
        case .submitting:
            Section { HStack { ProgressView(); Text("Submitting…").foregroundStyle(.secondary) } }
        case .pending(let hash):
            Section {
                HStack { ProgressView(); Text("Waiting for confirmation…").foregroundStyle(.secondary) }
                DetailRow(label: "UserOp", value: String(hash.prefix(10)) + "…", monospaced: true)
            }
        case .confirmed(let receipt):
            Section {
                if receipt.success {
                    Label("Confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    ErrorText(message: "Included onchain but the call reverted\(receipt.reason.map { ": \($0)" } ?? "")")
                }
                if let tx = receipt.transactionHash {
                    Link(destination: model.chain.explorerTransactionURL(tx)) {
                        Label("View on explorer", systemImage: "arrow.up.right.square")
                    }
                }
            }
        case .failed(let message):
            Section { ErrorText(message: message) }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch phase {
        case .ready(let prepared):
            Button {
                Task { await confirm(prepared) }
            } label: {
                Label(
                    model.signer.usesSecurityKey ? "Confirm with security key" : "Confirm",
                    systemImage: model.signer.usesSecurityKey ? "key.horizontal.fill" : "checkmark"
                )
                .frame(maxWidth: .infinity)
            }
            .primaryAction()
            .disabled(balance < prepared.requiredBalance)
        case .failed:
            Button("Try again") { Task { await prepare() } }
                .primaryAction()
        default:
            EmptyView()
        }
    }

    private var isBusy: Bool {
        switch phase {
        case .signing, .submitting, .pending: true
        default: false
        }
    }

    private var isFinished: Bool {
        if case .confirmed = phase { return true }
        return false
    }

    private func prepare() async {
        guard let account = model.account else { return }
        phase = .preparing
        prepared = nil
        do {
            let signingIndex = model.ownerKeys.first?.ownerIndex ?? 0
            async let preparedTask = account.prepare(calls: request.calls, signingOwnerIndex: signingIndex)
            async let balanceTask = account.balance()
            let (op, balance) = try await (preparedTask, balanceTask)
            prepared = op
            self.balance = balance
            phase = .ready(op)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func confirm(_ prepared: PreparedOperation) async {
        guard let account = model.account else { return }
        do {
            phase = .signing
            let op = try await account.sign(prepared, signer: model.signer, owners: model.ownerKeys)
            phase = .submitting
            let hash = try await account.submit(op)
            phase = .pending(hash)
            let receipt = try await account.bundler.waitForReceipt(hash)
            phase = .confirmed(receipt)
            if receipt.success { request.onConfirmed?(receipt) }
            await model.refresh()
        } catch SecurityKeyError.cancelled {
            phase = .ready(prepared)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
