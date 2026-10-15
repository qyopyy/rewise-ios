import Foundation

/// Checks bank details before they reach the server.
enum Validate {
    static func cleanIBAN(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace }
    }

    static func groupedIBAN(_ text: String) -> String {
        let chars = Array(cleanIBAN(text))
        return stride(from: 0, to: chars.count, by: 4)
            .map { String(chars[$0..<min($0 + 4, chars.count)]) }
            .joined(separator: " ")
    }

    /// Hungarian IBAN: "HU" + 2 check digits + 24 digits, verified with the ISO 13616 mod-97 check.
    static func isHungarianIBAN(_ text: String) -> Bool {
        let iban = cleanIBAN(text)
        guard iban.count == 28, iban.hasPrefix("HU"),
              iban.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        let rearranged = String(iban.dropFirst(4)) + String(iban.prefix(4))
        var remainder = 0
        for ch in rearranged {
            if let digit = ch.wholeNumberValue, ch.isASCII {
                remainder = (remainder * 10 + digit) % 97
            } else if let ascii = ch.asciiValue, ch.isLetter {
                remainder = (remainder * 100 + Int(ascii) - 55) % 97
            } else {
                return false
            }
        }
        return remainder == 1
    }

    /// US ABA routing number: 9 digits with the 3-7-1 checksum.
    static func isABARouting(_ text: String) -> Bool {
        let digits = text.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
        guard text.count == 9, digits.count == 9 else { return false }
        let sum = 3 * (digits[0] + digits[3] + digits[6])
            + 7 * (digits[1] + digits[4] + digits[7])
            + (digits[2] + digits[5] + digits[8])
        return sum % 10 == 0
    }

    static func isUSAccountNumber(_ text: String) -> Bool {
        (4...17).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func ibanHint(_ text: String) -> (message: String, ok: Bool?) {
        let iban = cleanIBAN(text)
        if iban.isEmpty { return ("Find it in the recipient's banking app. It starts with HU.", nil) }
        if !iban.hasPrefix("HU") { return ("Hungarian IBANs start with HU.", false) }
        if iban.count < 28 { return ("\(iban.count) of 28 characters", nil) }
        if iban.count > 28 { return ("Too long. A Hungarian IBAN has 28 characters.", false) }
        return isHungarianIBAN(iban)
            ? ("Valid IBAN · \(groupedIBAN(iban))", true)
            : ("The check digits don't match. Look for a typo.", false)
    }

    static func routingHint(_ text: String) -> (message: String, ok: Bool?) {
        if text.isEmpty { return ("9 digits, printed at the bottom left of a check.", nil) }
        if !text.allSatisfy({ $0.isASCII && $0.isNumber }) { return ("Use digits only.", false) }
        if text.count < 9 { return ("\(9 - text.count) more digits", nil) }
        return isABARouting(text)
            ? ("Valid routing number", true)
            : ("This number fails the routing check. Copy it again from the bank.", false)
    }
}
