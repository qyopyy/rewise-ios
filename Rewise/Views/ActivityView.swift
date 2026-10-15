import SwiftUI

struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: ActivityFilter = .all
    @State private var query = ""

    enum ActivityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case moneyOut = "Money out"
        case moneyIn = "Money in"
        var id: String { rawValue }
    }

    private var filtered: [Transfer] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.transfers.filter { transfer in
            switch filter {
            case .all: break
            case .moneyOut: if transfer.kind != .outgoing { return false }
            case .moneyIn: if transfer.kind != .incoming { return false }
            }
            if needle.isEmpty { return true }
            let haystack = [transfer.counterparty, transfer.shortReference, transfer.reference ?? "", transfer.counterpartyAccount ?? ""]
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(needle)
        }
    }

    struct DayGroup: Identifiable {
        let title: String
        var items: [Transfer]
        var id: String { title }
    }

    private var groups: [DayGroup] {
        var result: [DayGroup] = []
        for transfer in filtered {
            let title = Fmt.dayTitle(transfer.createdAt)
            if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].items.append(transfer)
            } else {
                result.append(DayGroup(title: title, items: [transfer]))
            }
        }
        return result
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(ActivityFilter.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.items) { transfer in
                        NavigationLink(value: transfer) {
                            TransferRow(transfer: transfer)
                        }
                    }
                }
            }
        }
        .overlay {
            if groups.isEmpty && !store.isLoading {
                if query.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "list.bullet", description: Text("Transfers you send and receive show up here."))
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .searchable(text: $query, prompt: "Name, note or reference")
        .navigationTitle("Activity")
        .navigationDestination(for: Transfer.self) { transfer in
            TransferDetailView(transferID: transfer.id)
        }
        .refreshable { await store.refreshTransfers() }
        .task { await store.refreshTransfers() }
    }
}

struct TransferDetailView: View {
    @Environment(AppStore.self) private var store
    let transferID: String

    var body: some View {
        if let transfer = store.transfers.first(where: { $0.id == transferID }) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(headline(transfer))
                            .font(Theme.display(34, relativeTo: .title))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        StatusPill(status: transfer.status)
                    }
                    .padding(.vertical, 6)
                }
                Section("Details") {
                    row("Reference", transfer.shortReference, mono: true)
                    row(transfer.kind == .incoming ? "From" : "To", transfer.counterparty)
                    if let account = transfer.counterpartyAccount {
                        row("Account", account, mono: true)
                    }
                    if transfer.kind == .outgoing {
                        row("You sent", Fmt.money(transfer.sourceAmount, transfer.sourceCurrency))
                        row("Rewise fee", Fmt.money(transfer.fee, transfer.sourceCurrency))
                        if let rate = transfer.rate {
                            row("Exchange rate", "1 USD = \(Fmt.rate(rate)) Ft")
                        }
                        row("Recipient gets", Fmt.money(transfer.targetAmount, transfer.targetCurrency))
                        if let speed = transfer.speed {
                            row("Delivery", speed.title)
                        }
                        if let eta = transfer.estimatedDelivery, transfer.status == .processing {
                            row("Should arrive", Fmt.day(eta))
                        }
                    }
                    if let note = transfer.reference, !note.isEmpty {
                        row("Note", note)
                    }
                    row("Date", transfer.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if store.demoMode {
                    Section {
                        Text("Sample record from demo mode.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .navigationTitle(transfer.kind == .incoming ? "Money in" : "Transfer")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Transfer not found", systemImage: "questionmark.circle")
        }
    }

    private func headline(_ transfer: Transfer) -> String {
        transfer.kind == .incoming
            ? "+" + Fmt.money(transfer.targetAmount, transfer.targetCurrency)
            : "\u{2212}" + Fmt.money(transfer.sourceAmount, transfer.sourceCurrency)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(mono ? .body.monospaced() : .body)
                .multilineTextAlignment(.trailing)
        }
    }
}
