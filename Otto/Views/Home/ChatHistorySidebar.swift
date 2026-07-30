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

            OttoDivider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.label) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.label)
                                .font(Theme.Typography.label)
                                .tracking(Theme.Tracking.xwide)
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.Colors.tertiaryText)
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
                OttoDivider()
                clearAllButton
            }
        }
        .frame(width: 240)
        .background(Theme.Colors.panelWash)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.Colors.border)
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
            Text("History")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.text)
            Spacer()
            Button {
                appState.activeChatSessionId = nil
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("New")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.Colors.onAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.accent)
                )
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(isActive ? Theme.Colors.accentText : Theme.Colors.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(relativeTime(session.updatedAt))
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                Spacer(minLength: 0)
                if appState.chatRuns.isRunning(session.id) {
                    RunningDot()
                        .help("Otto is working on this chat")
                }
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
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(
                        isActive
                            ? Theme.Colors.selectTint
                            : (isHovered ? Theme.Colors.hoverTint : Color.clear)
                    )
            )
            .padding(.horizontal, 6)
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
                Text("Clear all")
                    .font(.system(size: 11, weight: .medium))
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
            Text("No history yet")
                .font(.system(size: 12, weight: .medium))
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
        if !today.isEmpty     { out.append(Group(label: "Today",     sessions: today)) }
        if !yesterday.isEmpty { out.append(Group(label: "Yesterday", sessions: yesterday)) }
        if !thisWeek.isEmpty  { out.append(Group(label: "This week", sessions: thisWeek)) }
        if !earlier.isEmpty   { out.append(Group(label: "Earlier",   sessions: earlier)) }
        return out
    }

    // MARK: - Running indicator

    /// Pulsing dot marking the session with an in-flight agent run — the
    /// chat keeps working (and keeps saving) even when it's not the one on
    /// screen, and this is how the user finds their way back to it.
    private struct RunningDot: View {
        @State private var pulsing = false

        var body: some View {
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 6, height: 6)
                .opacity(pulsing ? 1 : 0.4)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
        }
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
