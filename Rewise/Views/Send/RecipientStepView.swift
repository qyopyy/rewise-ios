import SwiftUI

struct RecipientStepView: View {
    @Environment(AppStore.self) private var store
    @Bindable var model: SendModel
    @State private var showAdd = false

    private var options: [Recipient] {
        store.recipients.filter { $0.kind == model.corridor.recipientKind }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StepHeader(current: 2)
                Text(model.corridor == .huToUS ? "Who are you paying in the US?" : "Who are you paying in Hungary?")
                    .font(.title3.weight(.bold))
                VStack(spacing: 8) {
                    ForEach(options) { recipient in
                        RecipientOption(recipient: recipient, selected: model.recipient?.id == recipient.id) {
                            model.recipient = recipient
                        }
                    }
                    Button {
                        showAdd = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.headline)
                                .frame(width: 38, height: 38)
                                .background(Theme.sheet2, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("New recipient").font(.subheadline.weight(.semibold))
                                Text(model.corridor == .huToUS ? "Routing and account number" : "Hungarian IBAN")
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .foregroundStyle(Theme.ink)
                        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Theme.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reference (optional)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    TextField(model.corridor == .huToUS ? "e.g. October rent" : "e.g. Szülinapi ajándék", text: $model.reference)
                        .padding(12)
                        .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.rule, lineWidth: 1))
                        .onChange(of: model.reference) { _, newValue in
                            if newValue.count > 40 { model.reference = String(newValue.prefix(40)) }
                        }
                    Text("Shown on the recipient's bank statement.")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Button("Review transfer") {
                    model.step = .review
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.recipient == nil)
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                AddRecipientView(initialKind: model.corridor.recipientKind, lockedKind: true) { recipient in
                    model.recipient = recipient
                }
            }
            .environment(store)
        }
    }
}

struct RecipientOption: View {
    let recipient: Recipient
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                InitialsAvatar(name: recipient.name, country: recipient.kind.currency.countryCode)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipient.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(recipient.maskedAccount)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.navy : Theme.rule)
            }
            .padding(12)
            .foregroundStyle(Theme.ink)
            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Theme.navy : Theme.rule, lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
