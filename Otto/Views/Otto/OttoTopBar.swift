import SwiftUI

/// Top bar — brand on the left, search pill in the middle, indexed count +
/// live status + avatar on the right (mockup .topbar).
struct OttoTopBar: View {
    @Environment(AppState.self) private var appState

    /// Invoked when the user clicks the search pill (or presses ⌘K).
    var onSearch: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            // Brand
            HStack(spacing: 9) {
                BrandMark(size: 20)
                Text("Otto")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.text)
            }
            .layoutPriority(1)

            Spacer(minLength: 12)

            // Search pill
            Button {
                onSearch?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                    Text("Search or jump to…")
                        .font(.system(size: 12.5))
                    Spacer(minLength: 8)
                    Text("⌘K")
                        .font(Theme.Typography.monoSmall)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )
                }
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: 420)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.Colors.bgInput)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)

            Spacer(minLength: 12)

            // Status
            HStack(spacing: 14) {
                Text("\(indexLabel) indexed")
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                HStack(spacing: 6) {
                    PulseDot(color: statusColor, size: 6)
                    Text(statusLabel)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.textDim)
                }

                // Avatar
                Text("U")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accentText)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(Theme.Colors.selectTint)
                    )
                    .overlay(
                        Circle().strokeBorder(Theme.Colors.border, lineWidth: 1)
                    )
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .background(Theme.Colors.bg1)
        .overlay(alignment: .bottom) {
            OttoDivider()
        }
    }

    // MARK: - Derived data

    private var statusLabel: String {
        appState.errorMessage != nil ? "Error" : "Live"
    }

    private var statusColor: Color {
        appState.errorMessage != nil ? Theme.Colors.red : Theme.Colors.green
    }

    private var indexLabel: String {
        let total = appState.todos.count
            + appState.notes.count
            + appState.ideas.count
            + appState.reminders.count
            + appState.bookmarks.count
            + appState.meetings.count
            + appState.emails.count
            + appState.connections.count
            + appState.files.count
            + appState.xPosts.count
            + appState.xFollowers.count
            + appState.xDirectMessages.count
        return OttoFormatters.decimal.string(from: NSNumber(value: total)) ?? "\(total)"
    }
}
