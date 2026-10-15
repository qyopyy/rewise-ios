import Foundation

extension Decimal {
    /// Rounds to `scale` decimal places.
    func rounded(scale: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var input = self
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }

    var doubleValue: Double { NSDecimalNumber(decimal: self).doubleValue }
}

/// Formatting rules: forint the Hungarian way (1 284 500 Ft), dollars the US way ($8,420.37).
enum Fmt {
    static let huLocale = Locale(identifier: "hu_HU")
    static let usLocale = Locale(identifier: "en_US")
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func money(_ value: Decimal, _ currency: Currency) -> String {
        switch currency {
        case .HUF:
            return value.formatted(.currency(code: "HUF").locale(huLocale).precision(.fractionLength(0)))
        case .USD:
            return value.formatted(.currency(code: "USD").locale(usLocale).precision(.fractionLength(2)))
        }
    }

    /// Number without the currency sign, for amount fields.
    static func plain(_ value: Decimal, _ currency: Currency) -> String {
        let locale = currency == .HUF ? huLocale : usLocale
        return value.formatted(.number.locale(locale).precision(.fractionLength(currency.fractionDigits)))
    }

    static func rate(_ value: Decimal) -> String {
        value.formatted(.number.locale(usLocale).precision(.fractionLength(2)))
    }

    /// 0.0045 -> "0.45%"
    static func percent(_ value: Decimal) -> String {
        value.formatted(.percent.locale(usLocale).precision(.fractionLength(0...2)))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    static func relative(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Reads what people type: "250 000", "250,000", "1.234,56" or "1,234.56".
    static func parse(_ text: String, _ currency: Currency) -> Decimal? {
        var s = text.filter { "0123456789.,".contains($0) }
        if s.isEmpty { return nil }
        if currency == .HUF {
            s = s.filter { $0.isASCII && $0.isNumber }
            return s.isEmpty ? nil : Decimal(string: s, locale: posix)
        }
        let commas = s.filter { $0 == "," }.count
        if let lastComma = s.lastIndex(of: ","), let lastDot = s.lastIndex(of: ".") {
            if lastComma > lastDot {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if let lastComma = s.lastIndex(of: ",") {
            let digitsAfter = s.distance(from: lastComma, to: s.endIndex) - 1
            if commas == 1 && digitsAfter != 3 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }
        return Decimal(string: s, locale: posix)
    }
}
