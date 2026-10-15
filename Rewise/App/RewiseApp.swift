import SwiftUI

@main
struct RewiseApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(Theme.navy)
        }
    }
}
