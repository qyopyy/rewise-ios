import Foundation

/// Demo backend that runs inside the app. Same contract as `LiveAPI`, sample data only.
/// Prices follow the same rules as the web demo: 0.45% (Standard) or 0.85% (Instant)
/// plus 390 Ft or $1, at the mid-market rate.
actor MockAPI: RewiseAPI {
    private var accountList: [Account]
    private var recipientList: [Recipient]
    private var transferList: [Transfer]
    private var quotes: [String: Quote] = [:]
    private var idempotency: [String: String] = [:]
    private var mid: Decimal = Decimal(string: "324.41")!
    private let previousClose: Decimal = Decimal(string: "326.53")!

    init() {
        accountList = [
            Account(id: "acc_huf", currency: .HUF, balance: 1_284_500, maskedNumber: "HU•• •••• 2048"),
            Account(id: "acc_usd", currency: .USD, balance: Decimal(string: "8420.37")!, maskedNumber: "ACH •••• 6630"),
        ]
        recipientList = [
            Recipient(id: "rcp_1", name: "Emily Carter", kind: .usBank, maskedAccount: "Checking •••• 4821"),
            Recipient(id: "rcp_2", name: "Daniel Brooks", kind: .usBank, maskedAccount: "Savings •••• 7733"),
            Recipient(id: "rcp_3", name: "Kovács Anna", kind: .huBank, maskedAccount: "HU42 •••• •••• 4417"),
            Recipient(id: "rcp_4", name: "Tóth Bence", kind: .huBank, maskedAccount: "HU86 •••• •••• 9012"),
        ]
        transferList = MockAPI.seedTransfers(now: Date())
    }

    // MARK: - Contract

    func accounts() async throws -> [Account] {
        try await pause(0.3)
        return accountList
    }

    func rate() async throws -> FXRate {
        try await pause(0.15)
        let wiggle = Decimal(Double.random(in: -0.05...0.05)).rounded(scale: 4)
        mid = (mid + wiggle).rounded(scale: 4)
        return FXRate(base: .USD, quote: .HUF, mid: mid, previousClose: previousClose, timestamp: Date())
    }

    func rateHistory(days: Int) async throws -> [RatePoint] {
        try await pause(0.2)
        // Recent closes the demo history is drawn around: (days ago, forint per dollar).
        let anchors: [(Int, Double)] = [
            (89, 316.5), (85, 318.5), (82, 317.0), (76, 314.5), (60, 312.8), (45, 313.9), (38, 312.6),
            (33, 313.4), (30, 318.8), (15, 323.6), (13, 327.9), (10, 327.6), (9, 324.5), (8, 325.3),
            (6, 325.7), (4, 326.8), (2, 325.6), (1, 326.5), (0, 324.41),
        ]
        let count = min(max(days, 2), 90)
        var seed: UInt64 = 1015
        var points: [RatePoint] = []
        for index in 0..<count {
            let ago = count - 1 - index
            var j = 0
            while j < anchors.count - 1 && anchors[j + 1].0 >= ago { j += 1 }
            let a0 = anchors[j]
            let a1 = anchors[min(j + 1, anchors.count - 1)]
            let t = a0.0 == a1.0 ? 0 : Double(a0.0 - ago) / Double(a0.0 - a1.0)
            var value = a0.1 + (a1.1 - a0.1) * t
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5
            if !anchors.contains(where: { $0.0 == ago }) { value *= 1 + noise * 0.004 }
            let date = Calendar.current.date(byAdding: .day, value: -ago, to: Date()) ?? Date()
            points.append(RatePoint(date: date, rate: value))
        }
        if let last = points.last {
            points[points.count - 1] = RatePoint(date: last.date, rate: mid.doubleValue)
        }
        return points
    }

    func quote(_ request: QuoteRequest) async throws -> Quote {
        try await pause(0.25)
        let source = request.sourceCurrency
        let target = request.targetCurrency
        guard source != target else { throw APIError.invalid("Pick two different currencies.") }
        let percent = request.speed.feePercent
        let fixed = AppConfig.fixedFee(for: source)
        let sendAmount: Decimal
        if let wanted = request.targetAmount, wanted > 0 {
            let needed = target == .USD ? wanted * mid : wanted / mid
            sendAmount = ((needed + fixed) / (1 - percent)).rounded(scale: source.fractionDigits, mode: .up)
        } else {
            sendAmount = (request.sourceAmount ?? 0).rounded(scale: source.fractionDigits)
        }
        guard sendAmount > 0 else { throw APIError.invalid("Enter an amount to send.") }
        let fee = (sendAmount * percent + fixed).rounded(scale: source.fractionDigits)
        let converted = max(sendAmount - fee, 0)
        let received = (target == .USD ? converted / mid : converted * mid).rounded(scale: target.fractionDigits, mode: .down)
        let delivery = request.speed == .instant
            ? Date().addingTimeInterval(300)
            : MockAPI.nextBusinessDay(country: target.countryCode)
        let quote = Quote(
            id: "q_" + UUID().uuidString.prefix(8).lowercased(),
            sourceCurrency: source,
            targetCurrency: target,
            sourceAmount: sendAmount,
            fee: fee,
            targetAmount: received,
            rate: mid,
            speed: request.speed,
            expiresAt: Date().addingTimeInterval(30 * 60),
            estimatedDelivery: delivery
        )
        quotes[quote.id] = quote
        return quote
    }

    func recipients() async throws -> [Recipient] {
        try await pause(0.2)
        return recipientList
    }

    func createRecipient(_ draft: RecipientDraft) async throws -> Recipient {
        try await pause(0.4)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { throw APIError.invalid("Enter the recipient's full name.") }
        let masked: String
        switch draft.kind {
        case .huBank:
            guard Validate.isHungarianIBAN(draft.iban) else { throw APIError.invalid("Check the IBAN.") }
            let iban = Validate.cleanIBAN(draft.iban)
            masked = "\(iban.prefix(4)) •••• •••• \(iban.suffix(4))"
        case .usBank:
            guard Validate.isABARouting(draft.routingNumber), Validate.isUSAccountNumber(draft.accountNumber) else {
                throw APIError.invalid("Check the routing and account numbers.")
            }
            masked = "\(draft.accountType.capitalized) •••• \(draft.accountNumber.suffix(4))"
        }
        let recipient = Recipient(id: "rcp_" + UUID().uuidString.prefix(8).lowercased(), name: name, kind: draft.kind, maskedAccount: masked)
        recipientList.insert(recipient, at: 0)
        return recipient
    }

    func transfers() async throws -> [Transfer] {
        try await pause(0.2)
        settle()
        return transferList
    }

    func createTransfer(_ request: TransferRequest) async throws -> Transfer {
        try await pause(0.6)
        if let existingID = idempotency[request.idempotencyKey],
           let existing = transferList.first(where: { $0.id == existingID }) {
            return existing
        }
        guard let quote = quotes[request.quoteId] else {
            throw APIError.invalid("That quote is no longer available. Get a new rate.")
        }
        guard quote.expiresAt > Date() else { throw APIError.quoteExpired }
        guard let recipient = recipientList.first(where: { $0.id == request.recipientId }) else {
            throw APIError.invalid("Pick a recipient.")
        }
        guard let index = accountList.firstIndex(where: { $0.currency == quote.sourceCurrency }) else {
            throw APIError.invalid("There's no \(quote.sourceCurrency.rawValue) account to send from.")
        }
        guard accountList[index].balance >= quote.sourceAmount else { throw APIError.insufficientFunds }
        accountList[index].balance -= quote.sourceAmount
        let transfer = Transfer(
            id: "tr_" + UUID().uuidString.prefix(10).lowercased(),
            kind: .outgoing,
            status: .processing,
            counterparty: recipient.name,
            counterpartyAccount: recipient.maskedAccount,
            sourceCurrency: quote.sourceCurrency,
            sourceAmount: quote.sourceAmount,
            targetCurrency: quote.targetCurrency,
            targetAmount: quote.targetAmount,
            fee: quote.fee,
            rate: quote.rate,
            speed: quote.speed,
            reference: request.reference,
            createdAt: Date(),
            estimatedDelivery: quote.estimatedDelivery,
            shortReference: MockAPI.shortReference(Date())
        )
        transferList.insert(transfer, at: 0)
        quotes[quote.id] = nil
        idempotency[request.idempotencyKey] = transfer.id
        return transfer
    }

    // MARK: - Helpers

    private func pause(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Demo transfers finish a few seconds after they're created.
    private func settle() {
        let now = Date()
        for index in transferList.indices where transferList[index].status == .processing {
            let wait: TimeInterval = transferList[index].speed == .instant ? 5 : 9
            if now.timeIntervalSince(transferList[index].createdAt) > wait {
                transferList[index].status = .completed
            }
        }
    }

    static let holidays: [String: Set<String>] = [
        "HU": ["2026-10-23", "2026-12-25", "2027-01-01"],
        "US": ["2026-11-11", "2026-11-26", "2026-12-25", "2027-01-01"],
    ]

    static func nextBusinessDay(country: String, from start: Date = Date()) -> Date {
        let calendar = Calendar(identifier: .gregorian)
        var day = start
        repeat {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        } while calendar.isDateInWeekend(day) || (holidays[country]?.contains(isoDay(day, calendar)) ?? false)
        return day
    }

    static func isoDay(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func shortReference(_ date: Date) -> String {
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<5).map { _ in letters.randomElement() ?? "X" })
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "RW-%02d%02d%02d-", (parts.year ?? 0) % 100, parts.month ?? 0, parts.day ?? 0) + code
    }

    static func seedTransfers(now: Date) -> [Transfer] {
        func make(_ id: String, _ kind: TransferKind, _ who: String, _ account: String?,
                  _ source: Currency, _ sourceAmount: Decimal, _ target: Currency, _ targetAmount: Decimal,
                  fee: Decimal = 0, rate: Decimal? = nil, speed: Speed? = nil, note: String? = nil,
                  hoursAgo: Double) -> Transfer {
            let created = now.addingTimeInterval(-hoursAgo * 3600)
            return Transfer(id: id, kind: kind, status: .completed, counterparty: who, counterpartyAccount: account,
                            sourceCurrency: source, sourceAmount: sourceAmount, targetCurrency: target, targetAmount: targetAmount,
                            fee: fee, rate: rate, speed: speed, reference: note, createdAt: created,
                            estimatedDelivery: nil, shortReference: shortReference(created))
        }
        return [
            make("tr_seed1", .outgoing, "Emily Carter", "Checking •••• 4821", .HUF, 250_000, .USD, Decimal(string: "765.95")!,
                 fee: 1515, rate: Decimal(string: "324.41")!, speed: .standard, note: "October studio rent", hoursAgo: 2.3),
            make("tr_seed2", .incoming, "Lakeview Media LLC", "ACH credit", .USD, 3200, .USD, 3200,
                 note: "Invoice 2026-041", hoursAgo: 27),
            make("tr_seed3", .outgoing, "Kovács Anna", "HU42 •••• •••• 4417", .USD, 400, .HUF, 128_926,
                 fee: Decimal(string: "4.40")!, rate: Decimal(string: "325.90")!, speed: .instant, note: "Szülinapi ajándék", hoursAgo: 73),
            make("tr_seed4", .incoming, "Account top-up", "From your Hungarian bank", .HUF, 500_000, .HUF, 500_000,
                 hoursAgo: 146),
            make("tr_seed5", .outgoing, "Tóth Bence", "HU86 •••• •••• 9012", .USD, 1150, .HUF, 371_146,
                 fee: Decimal(string: "6.18")!, rate: Decimal(string: "324.48")!, speed: .standard, note: "Albérlet október", hoursAgo: 220),
        ]
    }
}
