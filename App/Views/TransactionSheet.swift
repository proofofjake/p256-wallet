import SwiftUI
import WalletClient

/// What a screen wants executed. How it's described for review comes from the core, not from the screen.
struct TransactionRequest: Identifiable {
    let id = UUID()
    let title: String
    let calls: [Call]
    /// Lets the review name the function and decode its arguments (used only if the selector matches).
    var functionSignatures: [String] = []
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
    @State private var balance = "0x0"

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DetailRow(label: "Network", value: model.chain.name)
                    if let review = prepared?.review {
                        // Decoded by the core from the operation that will be signed.
                        ForEach(Array(review.details.enumerated()), id: \.offset) { _, detail in
                            DetailRow(label: detail.label, value: detail.value, monospaced: detail.monospaced)
                        }
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
        if let review = prepared?.review {
            Section("Network fee") {
                if review.sponsored {
                    Label("Sponsored by paymaster", systemImage: "gift")
                } else {
                    DetailRow(label: "Up to", value: "\(eth(review.maxGasCost)) ETH")
                }
                if review.deploysAccount {
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
            if !canAfford(prepared) {
                Section {
                    ErrorText(message: "Not enough ETH. This needs up to \(eth(prepared.review.requiredBalance)) ETH including gas; the wallet holds \(eth(balance)).")
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
            .disabled(!canAfford(prepared))
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

    private func canAfford(_ prepared: PreparedOperation) -> Bool {
        ((try? compareQuantities(a: balance, b: prepared.review.requiredBalance)) ?? -1) >= 0
    }

    private func eth(_ wei: String) -> String {
        (try? formatUnits(quantity: wei, decimals: 18, maxFractionDigits: 8)) ?? wei
    }

    private func prepare() async {
        guard let account = model.account else { return }
        phase = .preparing
        prepared = nil
        do {
            let signingIndex = model.ownerKeys.first?.ownerIndex ?? 0
            async let preparedTask = account.prepare(
                calls: request.calls,
                signingOwnerIndex: signingIndex,
                tokens: model.reviewTokens,
                functionSignatures: request.functionSignatures
            )
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
