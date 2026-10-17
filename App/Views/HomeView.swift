import SwiftUI
import WalletClient

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showReceive = false
    @State private var showSend = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                header
                notices
                assets
                Section("Advanced") {
                    NavigationLink { ContractCallView() } label: {
                        Label("Contract call", systemImage: "curlybraces")
                    }
                    NavigationLink { SignMessageView() } label: {
                        Label("Sign message", systemImage: "signature")
                    }
                }
            }
            .refreshable { await model.refresh() }
            .navigationTitle("Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { networkMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showReceive) { ReceiveView() }
            .sheet(isPresented: $showSend) { SendView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await model.refresh() }
        }
    }

    private var networkMenu: some View {
        @Bindable var model = model
        return Menu {
            Picker("Network", selection: $model.chain) {
                ForEach(Chain.all) { chain in
                    Text(chain.name).tag(chain)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(model.chain.isTestnet ? .orange : .blue).frame(width: 8, height: 8)
                Text(model.chain.name).font(.subheadline.weight(.medium))
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 16) {
                if let wallet = model.wallet {
                    HStack {
                        AddressText(address: wallet.address)
                        CopyButton(text: wallet.address, label: "")
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ethBalanceText)
                        .contentTransition(.numericText())
                    Text("ETH").foregroundStyle(.secondary)
                }
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)

                HStack(spacing: 12) {
                    Button { showReceive = true } label: {
                        Label("Receive", systemImage: "arrow.down").frame(maxWidth: .infinity)
                    }
                    Button { showSend = true } label: {
                        Label("Send", systemImage: "arrow.up").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = model.refreshError {
            Section { ErrorText(message: error) }
        }
        if model.isDeployed == false {
            Section {
                Label("Your account goes onchain with its first transaction. You can receive funds before then.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.chain.isTestnet, model.ethBalance?.isZeroQuantity == true {
                    Link(destination: URL(string: "https://portal.cdp.coinbase.com/products/faucet")!) {
                        Label("Get Base Sepolia test ETH", systemImage: "drop")
                    }
                }
            }
        }
    }

    private var ethBalanceText: String {
        model.ethBalance.flatMap { try? formatUnits(quantity: $0, decimals: 18, maxFractionDigits: 6) } ?? "—"
    }

    private var assets: some View {
        Section("Assets") {
            AssetRow(symbol: "ETH", name: "Ether", amount: ethBalanceText)
            ForEach(model.tokens) { token in
                AssetRow(symbol: token.token.symbol, name: token.token.name, amount: token.formatted)
            }
            if model.isRefreshing && model.tokens.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }
}

private struct AssetRow: View {
    let symbol: String
    let name: String
    let amount: String

    var body: some View {
        HStack {
            Text(String(symbol.prefix(1)))
                .font(.headline)
                .frame(width: 36, height: 36)
                .background(.tint.opacity(0.15), in: Circle())
            VStack(alignment: .leading) {
                Text(symbol).font(.headline)
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(amount).font(.system(.body, design: .rounded)).monospacedDigit()
        }
    }
}
