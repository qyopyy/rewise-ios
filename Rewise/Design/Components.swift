import SwiftUI
import LocalAuthentication

/// Round country flag drawn in code, so no image assets are needed.
struct FlagView: View {
    let country: String
    var size: CGFloat = 20

    var body: some View {
        Group {
            if country == "HU" {
                VStack(spacing: 0) {
                    Color(hex: 0xCD2A3E)
                    Color.white
                    Color(hex: 0x436F4D)
                }
            } else {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { stripe in
                            stripe % 2 == 0 ? Color(hex: 0xB22234) : Color.white
                        }
                    }
                    Color(hex: 0x3C3B6E)
                        .frame(width: size * 0.5, height: size * 0.54)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.rule, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

struct CurrencyTag: View {
    let currency: Currency

    var body: some View {
        HStack(spacing: 6) {
            FlagView(country: currency.countryCode, size: 18)
            Text(currency.rawValue).font(.subheadline.weight(.bold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.sheet2, in: Capsule())
        .overlay(Capsule().stroke(Theme.rule, lineWidth: 1))
    }
}

struct InitialsAvatar: View {
    let name: String
    var country: String? = nil

    private var tint: Color { country == "HU" ? Theme.burgundy : Theme.navy }

    private var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map { String($0) } }
            .joined()
            .uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.footnote.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.12), in: Circle())
            .overlay(alignment: .bottomTrailing) {
                if let country {
                    FlagView(country: country, size: 15)
                        .overlay(Circle().stroke(Theme.sheet, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    let status: TransferStatus

    private var color: Color {
        switch status {
        case .processing: return Theme.warn
        case .completed: return Theme.pos
        case .failed, .cancelled: return Theme.neg
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if status == .processing {
                ProgressView().controlSize(.mini)
            }
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct SummaryRow: View {
    let label: String
    let value: String
    var note: String? = nil

    init(_ label: String, _ value: String, note: String? = nil) {
        self.label = label
        self.value = value
        self.note = note
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(Theme.muted)
            if let note {
                Text(note).font(.caption).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }
}

struct TransferRow: View {
    let transfer: Transfer

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(transfer.counterparty)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(mainAmount)
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(transfer.kind == .incoming ? Theme.pos : Theme.ink)
                if transfer.status == .processing {
                    StatusPill(status: .processing)
                } else {
                    Text(secondLine)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        if transfer.kind == .incoming {
            Image(systemName: "arrow.down.left")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.pos)
                .frame(width: 38, height: 38)
                .background(Theme.pos.opacity(0.12), in: Circle())
        } else {
            InitialsAvatar(name: transfer.counterparty, country: transfer.targetCurrency.countryCode)
        }
    }

    private var subtitle: String {
        let when = Fmt.relative(transfer.createdAt)
        if transfer.kind == .incoming { return "Money in · \(when)" }
        let route = transfer.sourceCurrency == .HUF ? "Hungary → US" : "US → Hungary"
        if let speed = transfer.speed { return "\(route) · \(speed.title) · \(when)" }
        return "\(route) · \(when)"
    }

    private var mainAmount: String {
        transfer.kind == .incoming
            ? "+" + Fmt.money(transfer.targetAmount, transfer.targetCurrency)
            : "\u{2212}" + Fmt.money(transfer.sourceAmount, transfer.sourceCurrency)
    }

    private var secondLine: String {
        transfer.kind == .incoming
            ? transfer.targetCurrency.accountName
            : "→ " + Fmt.money(transfer.targetAmount, transfer.targetCurrency)
    }
}

/// Asks for Face ID, Touch ID or the passcode before money moves.
enum Biometrics {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var authError: NSError?
        // Simulators and devices without a passcode can't authenticate; let the demo continue there.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
