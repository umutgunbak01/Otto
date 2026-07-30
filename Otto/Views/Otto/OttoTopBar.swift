import SwiftUI

/// Stage top bar (mockup .top) — crumb (view · date) on the left, the ⌘K
/// search pill centered, and the live-index pill + chat controls + avatar on
/// the right. The brand moved into the sidebar; this bar spans only the
/// middle stage column.
struct OttoTopBar: View {
    @Environment(AppState.self) private var appState

    /// Current view name for the crumb.
    var title: String = "Home"
    /// Home shows chat controls (history / new chat) in the right cluster.
    var isHome: Bool = false
    /// Invoked when the user clicks the search pill (or presses ⌘K).
    var onSearch: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Crumb
            HStack(spacing: 9) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                Text("·")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                Text(Self.crumbDate.string(from: Date()).uppercased())
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Search pill
            Button {
                onSearch?()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                    Text("Search or jump to…")
                        .font(.system(size: 12.5))
                    Spacer(minLength: 8)
                    Text("⌘K")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Theme.Colors.panel2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )
                }
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.leading, 11)
                .padding(.trailing, 7)
                .frame(height: 34)
                .frame(minWidth: 240, maxWidth: 430)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Theme.Colors.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Theme.Colors.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .layoutPriority(1)

            // Right cluster
            HStack(spacing: 7) {
                livePill

                if isHome {
                    OttoGlyphButton(
                        systemImage: "clock.arrow.circlepath",
                        help: "Chat history",
                        isActive: appState.showChatHistory
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            appState.showChatHistory.toggle()
                        }
                    }
                    OttoGlyphButton(systemImage: "plus.bubble", help: "New chat") {
                        appState.activeChatSessionId = nil
                    }
                }

                OttoUserAvatar(size: 28)
                    .padding(.leading, 2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            OttoDivider()
        }
    }

    /// "N indexed | ● Live" capsule (mockup .live).
    private var livePill: some View {
        HStack(spacing: 7) {
            Text(indexLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.Colors.textDim)
            Text("indexed")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Colors.tertiaryText)
            Rectangle()
                .fill(Theme.Colors.borderStrong)
                .frame(width: 1, height: 10)
            PulseDot(color: statusColor, size: 5.5)
            Text(statusLabel)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.Colors.textDim)
        }
        .padding(.horizontal, 11)
        .frame(height: 27)
        .background(Capsule().fill(Color.clear))
        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 1))
        .fixedSize()
    }

    // MARK: - Derived data

    static let crumbDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d"
        return f
    }()

    private var statusLabel: String {
        appState.errorMessage != nil ? "Error" : "Live"
    }

    private var statusColor: Color {
        appState.errorMessage != nil ? Theme.Colors.red : Theme.Colors.green
    }

    private var indexLabel: String {
        let total = appState.todos.count
            + appState.activeNotes.count
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
