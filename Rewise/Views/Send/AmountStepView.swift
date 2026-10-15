import SwiftUI

struct AmountStepView: View {
    enum Field: Hashable {
        case send
        case receive
    }

    private struct QuoteKey: Hashable {
        let corridor: Corridor
        let speed: Speed
        let amount: String
        let receive: Bool
        let mid: Decimal?
    }

    @Environment(AppStore.self) private var store
    @Bindable var model: SendModel
    @FocusState private var focus: Field?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(current: 1)
                HStack(spacing: 8) {
                    ForEach(Corridor.allCases) { corridor in
                        CorridorButton(corridor: corridor, selected: model.corridor == corridor) {
                            switchCorridor(to: corridor)
                        }
                    }
                }
                amountBox(title: "You send", text: $model.sendText, currency: model.corridor.source, field: .send)
                HStack(spacing: 6) {
                    Circle().fill(Theme.pos).frame(width: 7, height: 7)
                    Text(rateText)
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                    Text("mid-market, no markup")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                amountBox(title: "Recipient gets", text: $model.receiveText, currency: model.corridor.target, field: .receive)
                HStack(spacing: 10) {
                    ForEach(Speed.allCases) { speed in
                        SpeedCard(speed: speed, corridor: model.corridor, selected: model.speed == speed) {
                            model.speed = speed
                        }
                    }
                }
                summary
                if let message = issue ?? model.quoteError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.neg)
                }
                Button {
                    focus = nil
                    model.step = .recipient
                } label: {
                    if model.quoting {
                        ProgressView()
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.quote == nil || model.quoting || issue != nil)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: quoteKey) { await fetchQuote() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
    }

    // MARK: - Pieces

    private var rateText: String {
        guard let mid = store.rate?.mid else { return "Getting the rate…" }
        return "1 USD = \(Fmt.rate(mid)) Ft"
    }

    private func amountBox(title: String, text: Binding<String>, currency: Currency, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 10) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .focused($focus, equals: field)
                    .onChange(of: text.wrappedValue) { _, _ in
                        if focus == field {
                            model.editingReceive = (field == .receive)
                        }
                    }
                CurrencyTag(currency: currency)
            }
            .padding(.horizontal, 14)
            .frame(height: 62)
            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(focus == field ? Theme.navy : Theme.rule, lineWidth: focus == field ? 2 : 1)
            )
            if field == .send, let balance = store.account(for: currency)?.balance {
                Text("Balance \(Fmt.money(balance, currency))")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            SummaryRow(
                "Rewise fee",
                model.quote.map { Fmt.money($0.fee, $0.sourceCurrency) } ?? "–",
                note: "\(Fmt.percent(model.speed.feePercent)) + \(Fmt.money(AppConfig.fixedFee(for: model.corridor.source), model.corridor.source))"
            )
            Divider()
            SummaryRow("We convert", model.quote.map { Fmt.money($0.sourceAmount - $0.fee, $0.sourceCurrency) } ?? "–")
            Divider()
            SummaryRow("Paid out by", model.speed.payout(for: model.corridor))
            Divider()
            SummaryRow("Should arrive", arrival)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.rule, lineWidth: 1))
    }

    private var arrival: String {
        if model.speed == .instant {
            return model.corridor == .huToUS ? "In minutes" : "In seconds"
        }
        if let date = model.quote?.estimatedDelivery {
            return "By " + Fmt.day(date)
        }
        return "1 business day"
    }

    private var issue: String? {
        guard let quote = model.quote else { return nil }
        let source = model.corridor.source
        if quote.sourceAmount < source.minimumSend {
            return "The minimum is \(Fmt.money(source.minimumSend, source))."
        }
        if let balance = store.account(for: source)?.balance, quote.sourceAmount > balance {
            return "Your \(source == .HUF ? "forint" : "dollar") balance is \(Fmt.money(balance, source)). Lower the amount."
        }
        return nil
    }

    // MARK: - Quoting

    private var quoteKey: QuoteKey {
        QuoteKey(
            corridor: model.corridor,
            speed: model.speed,
            amount: model.editingReceive ? model.receiveText : model.sendText,
            receive: model.editingReceive,
            mid: store.rate?.mid
        )
    }

    private func switchCorridor(to corridor: Corridor) {
        guard corridor != model.corridor else { return }
        focus = nil
        model.corridor = corridor
        model.editingReceive = false
        model.sendText = Fmt.plain(corridor.defaultAmount, corridor.source)
        model.receiveText = ""
        model.quote = nil
        model.recipient = nil
    }

    private func fetchQuote() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        if Task.isCancelled { return }
        let byReceive = model.editingReceive
        let text = byReceive ? model.receiveText : model.sendText
        let currency = byReceive ? model.corridor.target : model.corridor.source
        guard let amount = Fmt.parse(text, currency), amount > 0 else {
            model.quote = nil
            model.quoteError = nil
            if byReceive {
                if focus != .send { model.sendText = "" }
            } else if focus != .receive {
                model.receiveText = ""
            }
            return
        }
        model.quoting = true
        defer { model.quoting = false }
        do {
            let quote = try await store.quote(
                corridor: model.corridor,
                speed: model.speed,
                sourceAmount: byReceive ? nil : amount,
                targetAmount: byReceive ? amount : nil
            )
            if Task.isCancelled { return }
            model.quote = quote
            model.quoteError = nil
            if byReceive {
                if focus != .send { model.sendText = Fmt.plain(quote.sourceAmount, quote.sourceCurrency) }
            } else if focus != .receive {
                model.receiveText = Fmt.plain(quote.targetAmount, quote.targetCurrency)
            }
        } catch {
            if !Task.isCancelled {
                model.quote = nil
                model.quoteError = error.localizedDescription
            }
        }
    }
}

struct CorridorButton: View {
    let corridor: Corridor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                FlagView(country: corridor.source.countryCode, size: 18)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.muted)
                FlagView(country: corridor.target.countryCode, size: 18)
                Text(corridor.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(Theme.ink)
            .background(selected ? Theme.sheet : Theme.sheet2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Theme.navy : Theme.rule, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(corridor.routeText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SpeedCard: View {
    let speed: Speed
    let corridor: Corridor
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: speed == .instant ? "bolt.fill" : "clock")
                    Spacer()
                    Text(Fmt.percent(speed.feePercent))
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                }
                Text(speed.title).font(.subheadline.weight(.semibold))
                Text(speed.detail(for: corridor))
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Theme.ink)
            .background(selected ? Theme.navy.opacity(0.08) : Theme.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.navy : Theme.rule, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
