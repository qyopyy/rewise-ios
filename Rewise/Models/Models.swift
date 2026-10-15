import Foundation

// MARK: - Currencies and corridors

enum Currency: String, Codable, CaseIterable, Identifiable, Hashable {
    case HUF
    case USD

    var id: String { rawValue }
    var countryCode: String { self == .HUF ? "HU" : "US" }
    var name: String { self == .HUF ? "Hungarian forint" : "US dollar" }
    var fractionDigits: Int { self == .HUF ? 0 : 2 }
    var minimumSend: Decimal { self == .HUF ? 5000 : 10 }
    var accountName: String { self == .HUF ? "Forint account" : "Dollar account" }
}

enum Corridor: String, Codable, CaseIterable, Identifiable, Hashable {
    case huToUS = "HU_US"
    case usToHU = "US_HU"

    var id: String { rawValue }
    var source: Currency { self == .huToUS ? .HUF : .USD }
    var target: Currency { self == .huToUS ? .USD : .HUF }
    var title: String { self == .huToUS ? "To the US" : "To Hungary" }
    var routeText: String { self == .huToUS ? "Hungary → US" : "US → Hungary" }
    var recipientKind: RecipientKind { self == .huToUS ? .usBank : .huBank }
    var defaultAmount: Decimal { self == .huToUS ? 250_000 : 500 }
}

enum Speed: String, Codable, CaseIterable, Identifiable, Hashable {
    case standard
    case instant

    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "Instant" }
    var feePercent: Decimal { self == .standard ? Decimal(string: "0.0045")! : Decimal(string: "0.0085")! }

    func detail(for corridor: Corridor) -> String {
        switch (self, corridor) {
        case (.standard, _): return "1 business day"
        case (.instant, .huToUS): return "Usually minutes"
        case (.instant, .usToHU): return "Usually seconds"
        }
    }

    func payout(for corridor: Corridor) -> String {
        switch (self, corridor) {
        case (.standard, .huToUS): return "ACH transfer"
        case (.instant, .huToUS): return "Real-time payment"
        case (.standard, .usToHU): return "Local forint transfer"
        case (.instant, .usToHU): return "AFR instant payment"
        }
    }
}

// MARK: - Accounts and rates

struct Account: Codable, Identifiable, Hashable {
    let id: String
    let currency: Currency
    var balance: Decimal
    let maskedNumber: String
}

struct FXRate: Codable, Hashable {
    let base: Currency
    let quote: Currency
    /// Forint per 1 US dollar, mid-market.
    let mid: Decimal
    let previousClose: Decimal?
    let timestamp: Date
}

struct RatePoint: Codable, Hashable, Identifiable {
    let date: Date
    let rate: Double
    var id: Date { date }
}

// MARK: - Quotes

struct QuoteRequest: Codable {
    let sourceCurrency: Currency
    let targetCurrency: Currency
    let sourceAmount: Decimal?
    let targetAmount: Decimal?
    let speed: Speed
}

struct Quote: Codable, Identifiable, Hashable {
    let id: String
    let sourceCurrency: Currency
    let targetCurrency: Currency
    let sourceAmount: Decimal
    let fee: Decimal
    let targetAmount: Decimal
    /// Forint per 1 US dollar, locked until `expiresAt`.
    let rate: Decimal
    let speed: Speed
    let expiresAt: Date
    let estimatedDelivery: Date?
}

// MARK: - Recipients

enum RecipientKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case usBank = "us_bank"
    case huBank = "hu_bank"

    var id: String { rawValue }
    var currency: Currency { self == .usBank ? .USD : .HUF }
    var title: String { self == .usBank ? "US bank" : "Hungarian bank" }
    var sectionTitle: String { self == .usBank ? "United States" : "Hungary" }
}

struct Recipient: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: RecipientKind
    let maskedAccount: String
}

struct RecipientDraft: Codable {
    var name: String = ""
    var kind: RecipientKind = .usBank
    var iban: String = ""
    var routingNumber: String = ""
    var accountNumber: String = ""
    var accountType: String = "checking"
}

// MARK: - Transfers

enum TransferStatus: String, Codable, Hashable {
    case processing
    case completed
    case failed
    case cancelled

    var title: String {
        switch self {
        case .processing: return "Processing"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}

enum TransferKind: String, Codable, Hashable {
    case outgoing
    case incoming
}

struct Transfer: Codable, Identifiable, Hashable {
    let id: String
    let kind: TransferKind
    var status: TransferStatus
    let counterparty: String
    let counterpartyAccount: String?
    let sourceCurrency: Currency
    let sourceAmount: Decimal
    let targetCurrency: Currency
    let targetAmount: Decimal
    let fee: Decimal
    let rate: Decimal?
    let speed: Speed?
    let reference: String?
    let createdAt: Date
    let estimatedDelivery: Date?
    let shortReference: String
}

struct TransferRequest: Codable {
    let quoteId: String
    let recipientId: String
    let reference: String?
    let idempotencyKey: String
}
