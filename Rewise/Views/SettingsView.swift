import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var baseURL = ""
    @State private var token = ""
    @State private var saved = false

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Toggle("Demo mode", isOn: Binding(
                    get: { store.demoMode },
                    set: { store.setDemoMode($0) }
                ))
            } footer: {
                Text("Demo mode runs on sample data inside the app. Saving an access token below switches it off and uses your Rewise backend.")
            }

            Section {
                TextField("https://api.yourdomain.com", text: $baseURL)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(saved ? "Saved" : "Save connection") {
                    store.saveConnection(baseURL: baseURL, token: token)
                    saved = true
                }
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty || saved)
            } header: {
                Text("Backend")
            } footer: {
                Text("The app never holds Airwallex keys. It calls your backend over HTTPS, and your backend calls Airwallex. The token is kept in the iOS Keychain.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Data", value: store.demoMode ? "Sample data" : "Your backend")
                LabeledContent("Corridors", value: "Hungary ⇄ US")
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            baseURL = store.baseURLText
            token = store.token
            saved = false
        }
        .onChange(of: baseURL) { _, _ in saved = false }
        .onChange(of: token) { _, _ in saved = false }
    }
}
