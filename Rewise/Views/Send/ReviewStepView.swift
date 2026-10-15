import SwiftUI

struct ReviewStepView: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: SendModel
    @State private var lockedQuote: Quote? = nil
    @State private var loading = false
    @State private var sending = false
    @State private var errorMessage: String? = nil
    @State private var idempotencyKey = UUID().uuidString

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(current: 3)
                if let quote = lockedQuote, let recipient = model.recipient {
                    LockBanner(quote: quote)
                    amounts(quote)
                    details(quote, recipient)
                    Label(
                        store.demoMode
                            ? "Demo mode. Confirming simulates the transfer and moves no money."
                            : "You'll confirm with Face ID or your passcode.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.neg)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let expired = context.date >= quote.expiresAt
                        Button {
                            Task {
                                if expired {
                                    await lockRate()
                                } else {
                                    await confirm(quote, recipient)
                                }
                            }
                        } label: {
                            if sending {
                                ProgressView()
                            } else {
                                Text(expired ? "Get a new rate" : "Send \(Fmt.money(quote.sourceAmount, quote.sourceCurrency))")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(sending || loading)
                    }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't lock a rate", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try again") {
                            Task { await lockRate() }
                        }
                    }
                } else {
                    ProgressView("Locking your rate…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .task {
            if lockedQuote == nil { await lockRate() }
        }
    }

    // MARK: - Pieces

    private func amounts(_ quote: Quote) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You send").font(.caption).foregroundStyle(Theme.muted)
                Text(Fmt.money(quote.sourceAmount, quote.sourceCurrency))
                    .font(Theme.display(26, relativeTo: .title2))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 4)
            Image(systemName: "arrow.right").foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text("Recipient gets").font(.caption).foregroundStyle(Theme.muted)
                Text(Fmt.money(quote.targetAmount, quote.targetCurrency))
                    .font(Theme.display(26, relativeTo: .title2))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .card()
    }

    private func details(_ quote: Quote, _ recipient: Recipient) -> some View {
        VStack(spacing: 0) {
            SummaryRow("To", recipient.name)
            SummaryRow("Account", recipient.maskedAccount)
            Divider()
            SummaryRow("From", quote.sourceCurrency.accountName)
            Divider()
            SummaryRow("Rewise fee", Fmt.money(quote.fee, quote.sourceCurrency))
            Divider()
            SummaryRow("Exchange rate", "1 USD = \(Fmt.rate(quote.rate)) Ft")
            Divider()
            SummaryRow("Delivery", "\(quote.speed.title) · \(quote.speed.payout(for: model.corridor))")
            if !model.reference.isEmpty {
                Divider()
                SummaryRow("Reference", model.reference)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rule, lineWidth: 1))
    }

    // MARK: - Actions

    /// Gets a fresh quote for the amount from step 1; its rate holds until `expiresAt`.
    private func lockRate() async {
        guard let base = model.quote else {
            errorMessage = "Go back and enter an amount."
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            lockedQuote = try await store.quote(
                corridor: model.corridor,
                speed: model.speed,
                sourceAmount: base.sourceAmount,
                targetAmount: nil
            )
            idempotencyKey = UUID().uuidString
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func confirm(_ quote: Quote, _ recipient: Recipient) async {
        errorMessage = nil
        let reason = "Send \(Fmt.money(quote.sourceAmount, quote.sourceCurrency)) to \(recipient.name)"
        guard await Biometrics.confirm(reason: reason) else {
            errorMessage = "The transfer wasn't confirmed."
            return
        }
        sending = true
        defer { sending = false }
        do {
            let transfer = try await store.send(
                quote: quote,
                recipient: recipient,
                reference: model.reference.isEmpty ? nil : model.reference,
                idempotencyKey: idempotencyKey
            )
            model.transfer = transfer
            model.step = .done
        } catch APIError.quoteExpired {
            errorMessage = APIError.quoteExpired.errorDescription
            await lockRate()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Shows the locked rate and how long it holds.
struct LockBanner: View {
    let quote: Quote

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(quote.expiresAt.timeIntervalSince(context.date)))
            let tint = left > 0 ? Theme.navy : Theme.neg
            HStack(spacing: 10) {
                Image(systemName: left > 0 ? "lock.fill" : "exclamationmark.triangle.fill")
                Text(left > 0 ? "Rate locked at 1 USD = \(Fmt.rate(quote.rate)) Ft" : "The locked rate expired")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(String(format: "%d:%02d", left / 60, left % 60))
                    .font(.footnote.weight(.semibold).monospacedDigit())
            }
            .padding(12)
            .foregroundStyle(tint)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
