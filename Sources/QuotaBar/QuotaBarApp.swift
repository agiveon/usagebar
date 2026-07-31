import SwiftUI

@main
struct QuotaBarApp: App {
    @StateObject private var store = UsageStore(registry: ProviderRegistry.default)

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}
