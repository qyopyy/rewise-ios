import SwiftUI

enum AppTab: Hashable {
    case home
    case send
    case activity
    case recipients
    case settings
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: AppTab = .home

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { OverviewView(tab: $tab) }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            NavigationStack { SendFlowView(tab: $tab) }
                .tabItem { Label("Send", systemImage: "arrow.up.right") }
                .tag(AppTab.send)
            NavigationStack { ActivityView() }
                .tabItem { Label("Activity", systemImage: "list.bullet") }
                .tag(AppTab.activity)
            NavigationStack { RecipientsView() }
                .tabItem { Label("Recipients", systemImage: "person.2") }
                .tag(AppTab.recipients)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .task {
            await store.refresh()
            store.startTicker()
        }
    }
}
