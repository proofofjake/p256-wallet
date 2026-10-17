import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import WalletCore

struct AddressText: View {
    let address: Address
    var short = true

    var body: some View {
        Text(short ? address.short : address.checksummed)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
    }
}

struct CopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : "doc.on.doc")
        }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode").font(.largeTitle)
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct ErrorText: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.footnote)
    }
}

struct DetailRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

extension View {
    /// Full-width prominent action button styling used at the bottom of sheets.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
    }
}
