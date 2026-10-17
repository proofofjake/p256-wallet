import SwiftUI

@main
struct P256WalletApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.wallet != nil {
            HomeView()
        } else {
            OnboardingView()
        }
    }
}
