import SwiftUI
import Observation

/// State for one transfer, kept while the user moves between steps and tabs.
@Observable
final class SendModel {
    enum Step: Hashable {
        case amount
        case recipient
        case review
        case done
    }

    var step: Step = .amount
    var corridor: Corridor = .huToUS
    var speed: Speed = .standard
    var sendText: String = Fmt.plain(Corridor.huToUS.defaultAmount, .HUF)
    var receiveText: String = ""
    /// True when the user typed what the recipient should get, so the send amount follows.
    var editingReceive = false
    var quote: Quote? = nil
    var quoting = false
    var quoteError: String? = nil
    var recipient: Recipient? = nil
    var reference: String = ""
    var transfer: Transfer? = nil

    func back() {
        switch step {
        case .recipient: step = .amount
        case .review: step = .recipient
        default: break
        }
    }

    func reset(corridor newCorridor: Corridor? = nil) {
        if let newCorridor { corridor = newCorridor }
        step = .amount
        speed = .standard
        editingReceive = false
        sendText = Fmt.plain(corridor.defaultAmount, corridor.source)
        receiveText = ""
        quote = nil
        quoteError = nil
        recipient = nil
        reference = ""
        transfer = nil
    }
}

struct SendFlowView: View {
    @Environment(AppStore.self) private var store
    @Binding var tab: AppTab
    @State private var model = SendModel()

    private var title: String {
        switch model.step {
        case .amount: return "Send money"
        case .recipient: return "Recipient"
        case .review: return "Review"
        case .done: return "Transfer sent"
        }
    }

    var body: some View {
        Group {
            switch model.step {
            case .amount:
                AmountStepView(model: model)
            case .recipient:
                RecipientStepView(model: model)
            case .review:
                ReviewStepView(model: model)
            case .done:
                DoneStepView(model: model, tab: $tab)
            }
        }
        .background(Theme.paper)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if model.step == .recipient || model.step == .review {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.back()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
        }
        .onAppear(perform: applyPreset)
        .onChange(of: store.sendPreset) { _, _ in applyPreset() }
        .animation(.default, value: model.step)
    }

    private func applyPreset() {
        guard let preset = store.sendPreset else { return }
        store.sendPreset = nil
        if model.step == .done || model.corridor != preset || model.step == .amount {
            model.reset(corridor: preset)
        }
    }
}

/// Three-part progress bar shown at the top of each step.
struct StepHeader: View {
    let current: Int
    private let titles = ["Amount", "Recipient", "Review"]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<titles.count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(index < current ? Theme.navy : Theme.rule)
                        .frame(height: 3)
                    Text("\(index + 1). \(titles[index])")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(index < current ? Theme.ink : Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of 3")
    }
}
