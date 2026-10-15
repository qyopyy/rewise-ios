import SwiftUI

struct RecipientsView: View {
    @Environment(AppStore.self) private var store
    @State private var showAdd = false

    var body: some View {
        List {
            ForEach(RecipientKind.allCases) { kind in
                Section(kind.sectionTitle) {
                    let items = store.recipients.filter { $0.kind == kind }
                    if items.isEmpty {
                        Text("No saved recipients")
                            .foregroundStyle(Theme.muted)
                    }
                    ForEach(items) { recipient in
                        HStack(spacing: 12) {
                            InitialsAvatar(name: recipient.name, country: kind.currency.countryCode)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recipient.name).font(.subheadline.weight(.semibold))
                                Text(recipient.maskedAccount)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Recipients")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("Add recipient", systemImage: "plus") }
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                AddRecipientView(initialKind: .usBank, lockedKind: false) { _ in }
            }
            .environment(store)
        }
    }
}

struct AddRecipientView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: RecipientDraft
    @State private var saving = false
    @State private var errorMessage: String? = nil
    let lockedKind: Bool
    let onSaved: (Recipient) -> Void

    init(initialKind: RecipientKind, lockedKind: Bool, onSaved: @escaping (Recipient) -> Void) {
        var start = RecipientDraft()
        start.kind = initialKind
        _draft = State(initialValue: start)
        self.lockedKind = lockedKind
        self.onSaved = onSaved
    }

    private var isValid: Bool {
        guard draft.name.trimmingCharacters(in: .whitespaces).count >= 2 else { return false }
        switch draft.kind {
        case .huBank:
            return Validate.isHungarianIBAN(draft.iban)
        case .usBank:
            return Validate.isABARouting(draft.routingNumber) && Validate.isUSAccountNumber(draft.accountNumber)
        }
    }

    var body: some View {
        Form {
            if !lockedKind {
                Section {
                    Picker("Bank country", selection: $draft.kind) {
                        ForEach(RecipientKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Section("Recipient") {
                TextField(draft.kind == .huBank ? "Full name, e.g. Kovács Anna" : "Full name, e.g. Emily Carter", text: $draft.name)
                    .textContentType(.name)
                    .autocorrectionDisabled()
            }
            if draft.kind == .huBank {
                Section {
                    TextField("IBAN (HU + 26 digits)", text: $draft.iban)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Hungarian bank account")
                } footer: {
                    hintText(Validate.ibanHint(draft.iban))
                }
            } else {
                Section {
                    TextField("Routing number (9 digits)", text: $draft.routingNumber)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                    TextField("Account number", text: $draft.accountNumber)
                        .keyboardType(.numberPad)
                        .font(.body.monospaced())
                    Picker("Account type", selection: $draft.accountType) {
                        Text("Checking").tag("checking")
                        Text("Savings").tag("savings")
                    }
                } header: {
                    Text("US bank account")
                } footer: {
                    hintText(Validate.routingHint(draft.routingNumber))
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(Theme.neg)
                }
            }
        }
        .navigationTitle("Add recipient")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? "Saving…" : "Save") {
                    Task { await save() }
                }
                .disabled(!isValid || saving)
            }
        }
    }

    private func hintText(_ hint: (message: String, ok: Bool?)) -> Text {
        let color: Color
        if hint.ok == true {
            color = Theme.pos
        } else if hint.ok == false {
            color = Theme.neg
        } else {
            color = Theme.muted
        }
        return Text(hint.message).foregroundStyle(color)
    }

    private func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            let recipient = try await store.addRecipient(draft)
            onSaved(recipient)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
