import SwiftUI

struct DoneStepView: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: SendModel
    @Binding var tab: AppTab

    /// The latest copy from the store, so the status updates while this screen is open.
    private var transfer: Transfer? {
        guard let id = model.transfer?.id else { return nil }
        return store.transfers.first { $0.id == id } ?? model.transfer
    }

    var body: some View {
        ScrollView {
            if let transfer {
                let delivered = transfer.status == .completed
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill((delivered ? Theme.pos : Theme.warn).opacity(0.14))
                            .frame(width: 76, height: 76)
                        if delivered {
                            Image(systemName: "checkmark")
                                .font(.title.weight(.bold))
                                .foregroundStyle(Theme.pos)
                        } else {
                            ProgressView().controlSize(.large)
                        }
                    }
                    Text(delivered ? "Delivered" : "On its way")
                        .font(Theme.display(34, relativeTo: .title))
                    Text(sentence(transfer, delivered: delivered))
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                    Text("Ref \(transfer.shortReference)")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.sheet2, in: Capsule())
                    timeline(transfer, delivered: delivered)
                    if store.demoMode {
                        Label("Simulated in demo mode. No money moved.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                    Button("Send another") { model.reset() }
                        .buttonStyle(PrimaryButtonStyle())
                        .padding(.top, 6)
                    Button("View activity") { tab = .activity }
                        .font(.subheadline.weight(.semibold))
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: model.transfer?.id) {
            while !Task.isCancelled, let current = transfer, current.status == .processing {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await store.refreshTransfers()
            }
        }
    }

    private func sentence(_ transfer: Transfer, delivered: Bool) -> String {
        let amount = Fmt.money(transfer.targetAmount, transfer.targetCurrency)
        return delivered
            ? "\(transfer.counterparty) received \(amount)."
            : "\(transfer.counterparty) will receive \(amount)."
    }

    private func timeline(_ transfer: Transfer, delivered: Bool) -> some View {
        let rateLine = transfer.rate.map { "Converted at 1 USD = \(Fmt.rate($0)) Ft" } ?? "Converted"
        let steps: [(title: String, done: Bool)] = [
            ("Transfer created", true),
            (rateLine, true),
            (transfer.targetCurrency == .USD ? "Paid out to the US bank" : "Paid out to the Hungarian bank", delivered),
            (transfer.targetCurrency == .USD ? "Dollars delivered" : "Forint delivered", delivered),
        ]
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<steps.count, id: \.self) { index in
                HStack(spacing: 10) {
                    Image(systemName: steps[index].done ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(steps[index].done ? Theme.pos : Theme.warn)
                    Text(steps[index].title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(steps[index].done ? Theme.ink : Theme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
