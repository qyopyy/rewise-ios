import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(AppStore.self) private var store
    @Binding var tab: AppTab
    @State private var showForint = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let message = store.lastError {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.neg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }
                balanceCard
                rateCard
                activityCard
                Text(store.demoMode
                     ? "Demo mode: balances and transfers are sample data and no money moves."
                     : "Connected to your Rewise backend.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(Theme.paper)
        .navigationTitle("Rewise")
        .refreshable { await store.refresh() }
        .navigationDestination(for: Transfer.self) { transfer in
            TransferDetailView(transferID: transfer.id)
        }
    }

    // MARK: - Balance

    private var totalText: String {
        guard let usd = store.totalInUSD, let mid = store.rate?.mid else { return "…" }
        return showForint ? Fmt.money(usd * mid, .HUF) : Fmt.money(usd, .USD)
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(store.demoMode ? "TOTAL BALANCE · DEMO" : "TOTAL BALANCE")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.7))
                Spacer()
                Picker("Show total in", selection: $showForint) {
                    Text("USD").tag(false)
                    Text("HUF").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }
            Text(totalText)
                .font(Theme.display(44))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            HStack(spacing: 10) {
                Button { tab = .send } label: { Label("Send", systemImage: "arrow.up.right") }
                    .buttonStyle(HeroButtonStyle(primary: true))
                Button { tab = .recipients } label: { Label("Recipients", systemImage: "person.2") }
                    .buttonStyle(HeroButtonStyle())
            }
            HStack(spacing: 10) {
                ForEach(store.accounts) { account in
                    AccountTile(account: account, rate: store.rate?.mid) {
                        store.sendPreset = account.currency == .HUF ? .huToUS : .usToHU
                        tab = .send
                    }
                }
            }
        }
        .padding(20)
        .background(
            LinearGradient(colors: [Theme.heroTop, Theme.heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(alignment: .topTrailing) {
            GuillocheView()
                .frame(width: 260, height: 260)
                .offset(x: 90, y: -90)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Rate

    private var chartPoints: [RatePoint] { Array(store.history.suffix(30)) }

    private var dayChangeText: String? {
        guard let rate = store.rate, let previous = rate.previousClose, previous > 0 else { return nil }
        let change = ((rate.mid / previous) - 1) * 100
        let arrow = change >= 0 ? "▲" : "▼"
        return "\(arrow) \(Fmt.rate(abs(change)))% today"
    }

    private var rateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("USD / HUF").font(.subheadline.weight(.semibold))
                    Text(store.rate.map { Fmt.rate($0.mid) } ?? "…")
                        .font(Theme.display(34, relativeTo: .title))
                        .monospacedDigit()
                }
                Spacer()
                if let change = dayChangeText {
                    Text(change)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.sheet2, in: Capsule())
                }
            }
            if chartPoints.count > 1 {
                RateChart(points: chartPoints)
                    .frame(height: 160)
            }
            Text("Mid-market rate, refreshed every 15 seconds. Rewise adds no markup to it.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .card()
    }

    // MARK: - Activity

    private var recent: [Transfer] { Array(store.transfers.prefix(5)) }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recent activity").font(.subheadline.weight(.semibold))
                Spacer()
                Button("See all") { tab = .activity }
                    .font(.subheadline)
            }
            if recent.isEmpty {
                Text(store.isLoading ? "Loading…" : "No transfers yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, 8)
            }
            ForEach(recent) { transfer in
                NavigationLink(value: transfer) {
                    TransferRow(transfer: transfer)
                }
                .buttonStyle(.plain)
                if transfer.id != recent.last?.id {
                    Divider()
                }
            }
        }
        .card()
    }
}

struct AccountTile: View {
    let account: Account
    let rate: Decimal?
    let action: () -> Void

    private var equivalent: String? {
        guard let rate, rate > 0 else { return nil }
        return account.currency == .HUF
            ? "≈ " + Fmt.money(account.balance / rate, .USD)
            : "≈ " + Fmt.money(account.balance * rate, .HUF)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    FlagView(country: account.currency.countryCode, size: 16)
                    Text(account.currency.accountName).font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.white.opacity(0.75))
                Text(Fmt.money(account.balance, account.currency))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let equivalent {
                    Text(equivalent)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.65))
                        .lineLimit(1)
                }
                Text(account.maskedNumber)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(account.currency.accountName), \(Fmt.money(account.balance, account.currency)). Send from this account.")
    }
}

struct RateChart: View {
    let points: [RatePoint]

    private var domain: ClosedRange<Double> {
        let values = points.map(\.rate)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max((high - low) * 0.15, 0.5)
        return (low - pad)...(high + pad)
    }

    var body: some View {
        let range = domain
        Chart(points) { point in
            AreaMark(
                x: .value("Day", point.date),
                yStart: .value("Floor", range.lowerBound),
                yEnd: .value("Rate", point.rate)
            )
            .foregroundStyle(
                LinearGradient(colors: [Theme.navy.opacity(0.22), Theme.navy.opacity(0.0)], startPoint: .top, endPoint: .bottom)
            )
            .interpolationMethod(.monotone)
            LineMark(
                x: .value("Day", point.date),
                y: .value("Rate", point.rate)
            )
            .foregroundStyle(Theme.navy)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: range)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .accessibilityLabel("US dollar to forint rate over the last 30 days")
    }
}
