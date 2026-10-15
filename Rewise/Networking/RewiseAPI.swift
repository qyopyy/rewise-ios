import Foundation

/// Everything the app needs from a backend. `LiveAPI` calls your server;
/// `MockAPI` runs the same contract on sample data inside the app.
protocol RewiseAPI {
    func accounts() async throws -> [Account]
    func rate() async throws -> FXRate
    func rateHistory(days: Int) async throws -> [RatePoint]
    func quote(_ request: QuoteRequest) async throws -> Quote
    func recipients() async throws -> [Recipient]
    func createRecipient(_ draft: RecipientDraft) async throws -> Recipient
    func transfers() async throws -> [Transfer]
    func createTransfer(_ request: TransferRequest) async throws -> Transfer
}

enum APIError: LocalizedError {
    case notSignedIn
    case quoteExpired
    case insufficientFunds
    case invalid(String)
    case server(status: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Add your backend address and access token in Settings, or turn on demo mode."
        case .quoteExpired:
            return "The locked rate expired. Get a new rate and try again."
        case .insufficientFunds:
            return "Your balance is too low for this transfer."
        case .invalid(let message):
            return message
        case .server(let status, let message):
            return message.isEmpty ? "The server returned an error (\(status))." : message
        case .transport(let message):
            return message
        }
    }
}
