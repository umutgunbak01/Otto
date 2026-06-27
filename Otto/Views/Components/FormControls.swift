import SwiftUI

/// Shared Otto-styled form primitives, used by the Company/Event editors.
/// Mirrors the look of the inline helpers in `HabitCreatorSheet`.

struct FormField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).hudLabel(tracking: Theme.Tracking.wide)
            content()
        }
    }
}

struct FormText: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.text)
            .padding(Theme.Spacing.sm)
            .background(Theme.Colors.bg2)
            .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
    }
}

struct FormTextEditor: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .padding(.horizontal, Theme.Spacing.sm + 4)
                    .padding(.vertical, Theme.Spacing.sm + 2)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.text)
                .scrollContentBackground(.hidden)
                .padding(Theme.Spacing.xs)
                .frame(minHeight: 90)
        }
        .background(Theme.Colors.bg2)
        .overlay(Rectangle().stroke(Theme.Colors.border, lineWidth: 1))
    }
}

/// Parses and formats currency text for the commitment/budget fields.
enum MoneyField {
    /// String for editing — plain integer when whole, else one decimal. Empty for nil.
    static func string(from amount: Double?) -> String {
        guard let amount, amount > 0 else { return "" }
        if amount == amount.rounded() { return String(Int(amount)) }
        return String(amount)
    }

    /// Parse user input ("$50,000", "50k", "1.2m") into a Double. nil when blank/zero.
    static func amount(from text: String) -> Double? {
        var s = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        s.removeAll { $0 == "$" || $0 == "," || $0 == " " }

        var multiplier: Double = 1
        if s.hasSuffix("k") { multiplier = 1_000; s.removeLast() }
        else if s.hasSuffix("m") { multiplier = 1_000_000; s.removeLast() }
        else if s.hasSuffix("b") { multiplier = 1_000_000_000; s.removeLast() }

        guard let value = Double(s), value > 0 else { return nil }
        return value * multiplier
    }
}
