import Foundation
import Observation

/// App state shared by every screen.
@MainActor
@Observable
final class AppStore {
    var accounts: [Account] = []
    var recipients: [Recipient] = []
    var transfers: [Transfer] = []
    var rate: FXRate? = nil
    var history: [RatePoint] = []
    var isLoading = false
    var lastError: String? = nil
    /// Set by Home when a balance tile is tapped; the Send tab picks it up.
    var sendPreset: Corridor? = nil

    private(set) var demoMode: Bool
    private(set) var baseURLText: String
    private(set) var token: String

    @ObservationIgnored private var api: any RewiseAPI
    @ObservationIgnored private var ticker: Task<Void, Never>?
    private let mock: MockAPI

    init() {
        let defaults = UserDefaults.standard
        let demo = defaults.object(forKey: AppConfig.demoModeKey) as? Bool ?? true
        let base = defaults.string(forKey: AppConfig.baseURLKey) ?? AppConfig.defaultBaseURL.absoluteString
        let savedToken = Keychain.read(AppConfig.tokenKey) ?? ""
        let mockAPI = MockAPI()
        self.demoMode = demo
        self.baseURLText = base
        self.token = savedToken
        self.mock = mockAPI
        self.api = AppStore.makeAPI(demo: demo, base: base, token: savedToken, mock: mockAPI)
    }

    private static func makeAPI(demo: Bool, base: String, token: String, mock: MockAPI) -> any RewiseAPI {
        if demo { return mock }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: trimmed) ?? AppConfig.defaultBaseURL
        return LiveAPI(baseURL: url, token: token)
    }

    // MARK: - Connection

    func setDemoMode(_ on: Bool) {
        guard on != demoMode else { return }
        demoMode = on
        UserDefaults.standard.set(on, forKey: AppConfig.demoModeKey)
        reconnect()
    }

    func saveConnection(baseURL: String, token newToken: String) {
        baseURLText = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(baseURLText, forKey: AppConfig.baseURLKey)
        Keychain.write(token, for: AppConfig.tokenKey)
        // Saving a token means "use my backend", so demo mode switches off.
        if !token.isEmpty && demoMode {
            demoMode = false
            UserDefaults.standard.set(false, forKey: AppConfig.demoModeKey)
        }
        reconnect()
    }

    private func reconnect() {
        api = AppStore.makeAPI(demo: demoMode, base: baseURLText, token: token, mock: mock)
        accounts = []
        recipients = []
        transfers = []
        history = []
        rate = nil
        lastError = nil
        Task { await refresh() }
    }

    // MARK: - Loading

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        let client = api
        do {
            accounts = try await client.accounts()
            rate = try await client.rate()
            recipients = try await client.recipients()
            transfers = try await client.transfers()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        if history.isEmpty, let points = try? await client.rateHistory(days: 90) {
            history = points
        }
    }

    func refreshTransfers() async {
        if let list = try? await api.transfers() {
            transfers = list
        }
    }

    /// Keeps the rate fresh and picks up finished transfers while the app is open.
    func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if let fresh = try? await self.api.rate() {
                    self.rate = fresh
                }
                if self.transfers.contains(where: { $0.status == .processing }) {
                    await self.refreshTransfers()
                }
            }
        }
    }

    // MARK: - Actions

    func quote(corridor: Corridor, speed: Speed, sourceAmount: Decimal?, targetAmount: Decimal?) async throws -> Quote {
        let request = QuoteRequest(
            sourceCurrency: corridor.source,
            targetCurrency: corridor.target,
            sourceAmount: sourceAmount,
            targetAmount: targetAmount,
            speed: speed
        )
        return try await api.quote(request)
    }

    func send(quote: Quote, recipient: Recipient, reference: String?, idempotencyKey: String) async throws -> Transfer {
        let request = TransferRequest(quoteId: quote.id, recipientId: recipient.id, reference: reference, idempotencyKey: idempotencyKey)
        let transfer = try await api.createTransfer(request)
        transfers.removeAll { $0.id == transfer.id }
        transfers.insert(transfer, at: 0)
        if let fresh = try? await api.accounts() {
            accounts = fresh
        }
        return transfer
    }

    func addRecipient(_ draft: RecipientDraft) async throws -> Recipient {
        let recipient = try await api.createRecipient(draft)
        recipients.removeAll { $0.id == recipient.id }
        recipients.insert(recipient, at: 0)
        return recipient
    }

    func account(for currency: Currency) -> Account? {
        accounts.first { $0.currency == currency }
    }

    /// Everything converted to dollars at the mid-market rate.
    var totalInUSD: Decimal? {
        guard let mid = rate?.mid, mid > 0, !accounts.isEmpty else { return nil }
        return accounts.reduce(Decimal(0)) { sum, account in
            sum + (account.currency == .USD ? account.balance : account.balance / mid)
        }
    }
}
