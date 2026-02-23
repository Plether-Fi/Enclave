import SwiftUI

@main
struct EnclaveWalletApp: App {
    init() {
        WalletConnectService.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
