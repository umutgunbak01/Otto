import SwiftUI

/// Left rail of the chat sheet. Lists past sessions grouped by relative
/// time (Today / Yesterday / This week / Earlier) and lets the user switch
/// the active session, start a new chat, or delete an old one.
struct ChatHistorySidebar: View {
    @Environment(AppState.self) private var appState
    @State private var hoveredId: UUID?
    @State private var deleteCandidate: ChatSession?

    var body: some View {
        VStack(spacing: 0) {
            header

            OttoDivider(kind: .dashed)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.label) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.label)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(2.5)
                                .foregroundStyle(Theme.Colors.textDim)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                            ForEach(group.sessions) { session in
                                row(for: session)
                            }
                        }
                    }
                    if appState.chatSessions.isEmpty {
                        emptyState
                    }
                }
                .padding(.vertical, 8)
            }

            if !appState.chatSessions.isEmpty {
                OttoDivider(kind: .dashed)
                clearAllButton
            }
        }
        .frame(width: 240)
        .background(Theme.Colors.bg1.opacity(0.6))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.Colors.cyan.opacity(0.18))
                .frame(width: 1)
        }
        .alert("Delete chat?", isPresented: Binding(
            get: { deleteCandidate != nil },
            set: { if !$0 { deleteCandidate = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
            Button("Delete", role: .destructive) {
                if let target = deleteCandidate {
                    Task { await appState.deleteChatSession(target.id) }
                }
                deleteCandidate = nil
            }
        } message: {
            Text("\"\(deleteCandidate?.title ?? "")\" — this can't be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("⌬ HISTORY")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(3)
                .foregroundStyle(Theme.Colors.cyan)
                .shadow(color: Theme.Colors.cyanGlow, radius: 4)
            Spacer()
            Button {
                appState.activeChatSessionId = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("NEW")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(2)
                }
                .foregroundStyle(Theme.Colors.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .overlay(
                    Rectangle().stroke(Theme.Colors.cyan, lineWidth: 1)
                )
                .shadow(color: Theme.Colors.cyanGlow.opacity(0.4), radius: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Row

    private func row(for session: ChatSession) -> some View {
        let isActive = appState.activeChatSessionId == session.id
        let isHovered = hoveredId == session.id

        return Button {
            appState.activeChatSessionId = session.id
        } label: {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(isActive ? Theme.Colors.cyan : .clear)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(isActive ? Theme.Colors.cyan : Theme.Colors.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(relativeTime(session.updatedAt))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Theme.Colors.textDim)
                }
                Spacer(minLength: 0)
                if isHovered {
                    Button {
                        deleteCandidate = session
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Colors.textDim)
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .help("Delete chat")
                }
            }
            .padding(.vertical, 8)
            .padding(.trailing, 8)
            .background(
                isActive
                    ? Theme.Colors.cyan.opacity(0.10)
                    : (isHovered ? Theme.Colors.hoverTint : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredId = hovering ? session.id : (hoveredId == session.id ? nil : hoveredId)
        }
    }

    // MARK: - Clear all

    private var clearAllButton: some View {
        Button {
            Task { await appState.clearChatSessions() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                Text("CLEAR ALL")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(2)
            }
            .foregroundStyle(Theme.Colors.textDim)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 20, weight: .thin))
                .foregroundStyle(Theme.Colors.textDim)
                .padding(.bottom, 4)
            Text("NO HISTORY YET")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(2.5)
                .foregroundStyle(Theme.Colors.textDim)
            Text("Start a conversation to see it appear here.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textDim.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Grouping

    private struct Group: Identifiable {
        let id = UUID()
        let label: String
        let sessions: [ChatSession]
    }

    private var grouped: [Group] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday)!

        var today: [ChatSession] = []
        var yesterday: [ChatSession] = []
        var thisWeek: [ChatSession] = []
        var earlier: [ChatSession] = []

        for s in appState.chatSessions {
            if s.updatedAt >= startOfToday { today.append(s) }
            else if s.updatedAt >= startOfYesterday { yesterday.append(s) }
            else if s.updatedAt >= startOfWeek { thisWeek.append(s) }
            else { earlier.append(s) }
        }

        var out: [Group] = []
        if !today.isEmpty     { out.append(Group(label: "// TODAY",     sessions: today)) }
        if !yesterday.isEmpty { out.append(Group(label: "// YESTERDAY", sessions: yesterday)) }
        if !thisWeek.isEmpty  { out.append(Group(label: "// THIS WEEK", sessions: thisWeek)) }
        if !earlier.isEmpty   { out.append(Group(label: "// EARLIER",   sessions: earlier)) }
        return out
    }

    private func relativeTime(_ d: Date) -> String {
        let secs = Date().timeIntervalSince(d)
        if secs < 60 { return "just now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "\(mins)m ago" }
        let hours = mins / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days < 7 { return "\(days)d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }
}
