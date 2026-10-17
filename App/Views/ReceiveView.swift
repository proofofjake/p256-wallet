import SwiftUI
import WalletCore

struct ReceiveView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let address = model.wallet?.address {
                ScrollView {
                    VStack(spacing: 24) {
                        QRCodeView(text: address.checksummed)
                            .frame(width: 240, height: 240)
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))

                        AddressText(address: address, short: false)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        HStack {
                            CopyButton(text: address.checksummed)
                            ShareLink(item: address.checksummed)
                        }
                        .buttonStyle(.bordered)

                        Label(
                            "Send only \(model.chain.name) assets to this address. The same address works on other networks this wallet supports, but each network's balance is separate.",
                            systemImage: "info.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    }
                    .padding(.vertical, 24)
                }
                .navigationTitle("Receive")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
    }
}
