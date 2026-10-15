import Foundation

/// App-wide settings. The app never talks to Airwallex directly:
/// it calls your Rewise backend, which holds the Airwallex keys.
enum AppConfig {
    /// Default address of your backend: the `api` Edge Function on your Supabase project
    /// (source in backend/). You can also change it in Settings.
    static let defaultBaseURL = URL(string: "https://gctzysmrjbiqmolnopbm.supabase.co/functions/v1/api")!

    static let baseURLKey = "rewise.baseURL"
    static let demoModeKey = "rewise.demoMode"
    static let tokenKey = "rewise.accessToken"

    /// Fixed part of the Rewise fee, in the currency the customer sends.
    static func fixedFee(for currency: Currency) -> Decimal {
        currency == .HUF ? 390 : 1
    }
}
