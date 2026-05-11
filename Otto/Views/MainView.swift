import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Top-level Otto HUD shell. Lays the app out in the same grid as the
/// `otto-ui-mockup.html`:
///
///   ┌──────────────────────────────┐  topbar (full width)
///   │                              │
///   │ sidebar │ main hud │ right   │  body
///   │         │          │ rail    │
///   │         ├──────────┴─────────┤
///   │         │ dock               │  dock spans main + right
///   └──────────────────────────────┘
///
/// `main hud` swaps between the OttoHUD home, the floating chat, and the
/// individual list views depending on the sidebar selection.
struct MainView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    @State private var showingSettings = false
    @State private var showingIntegrations = false
    @State private var showingHome = true
    @State private var showingChat = false
    @State private var didOpenHUD = false

    #if os(macOS)
    @State private var undoMonitor: Any?
    #endif

    var body: some View {
        ZStack {
            // Animated grid + scanline + vignette ambient.
            GridBackground()

            GeometryReader { geo in
                // Side rails scale with width but clamp to sensible ranges so
                // the HUD never collapses on narrow windows or gets too wide on
                // ultrawide displays.
                let sidebarW = max(220, min(280, geo.size.width * 0.18))
                let railW    = max(280, min(360, geo.size.width * 0.20))
                let isCompact = geo.size.width < 1100

                VStack(spacing: 14) {
                    OttoTopBar()
                        .frame(height: 64)

                    HStack(spacing: 14) {
                        // Sidebar.
                        OttoSidebar(
                            showingHome: $showingHome,
                            showingSettings: $showingSettings,
                            showingIntegrations: $showingIntegrations
                        )
                        .frame(width: sidebarW)

                        VStack(spacing: 14) {
                            HStack(alignment: .top, spacing: 14) {
                                // Main HUD area.
                                mainContent
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                // Right rail — hidden on compact widths to
                                // keep the HUD breathing room.
                                if !isCompact {
                                    OttoRightPanel()
                                        .frame(width: railW)
                                        .frame(maxHeight: .infinity)
                                }
                            }
                            .frame(maxHeight: .infinity)

                            // Dock spans main + right.
                            OttoDock(
                                onSend: { text in
                                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !trimmed.isEmpty else { return }
                                    appState.pendingChatPrompt = trimmed
                                    showingChat = true
                                },
                                onMic: {
                                    appState.showVoiceOverlay = true
                                }
                            )
                            .frame(height: 80)
                        }
                    }
                }
                .padding(14)
            }

            // Voice overlay sits above everything when active.
            if appState.showVoiceOverlay {
                VoiceOverlayView(isPresented: Binding(
                    get: { appState.showVoiceOverlay },
                    set: { appState.showVoiceOverlay = $0 }
                ))
                .transition(.opacity)
                .zIndex(20)
            }

            // Undo toast.
            if appState.undoService.showToast {
                VStack {
                    Spacer()
                    UndoToastView(
                        label: appState.undoService.toastLabel,
                        onUndo: { Task { await appState.undoService.undo() } },
                        onDismiss: { appState.undoService.dismissToast() }
                    )
                    .padding(.bottom, 110)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: appState.undoService.showToast)
                .zIndex(15)
            }
        }
        .frame(minWidth: 960, minHeight: 680)
        .background(Theme.Colors.bg0)
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingIntegrations) {
            IntegrationsView()
        }
        .sheet(isPresented: $showingChat) {
            chatSheet
        }
        .task {
            if appState.todos.isEmpty
                && appState.notes.isEmpty
                && appState.ideas.isEmpty
                && appState.reminders.isEmpty
                && appState.bookmarks.isEmpty
                && appState.meetings.isEmpty {
                await appState.loadData()
            }
        }
        #if os(macOS)
        .onAppear {
            setupUndoMonitor()
            if !didOpenHUD {
                didOpenHUD = true
                openWindow(id: "hud")
            }
        }
        .onDisappear { removeUndoMonitor() }
        #endif
    }

    // MARK: - Main content area

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            if showingHome {
                OttoHUD()
            } else {
                listContent
                    .padding(20)
            }

            // Cyan corner brackets — the `.corners` flourishes in the mockup.
            OttoCorners()
        }
        .angledPanel(.all(20))
        .overlay(alignment: .topTrailing) {
            // Floating button to open the chat over the HUD.
            if showingHome {
                Button {
                    showingChat = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 11))
                        Text("CHAT")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.Colors.cyan.opacity(0.12))
                    .overlay(
                        Rectangle().stroke(Theme.Colors.cyan, lineWidth: 1)
                    )
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 8)
                }
                .buttonStyle(.plain)
                .padding(48)
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        switch appState.selectedTab {
        case .todo:       TodoListView()
        case .note:       NoteListView()
        case .idea:       IdeaListView()
        case .reminder:   ReminderListView()
        case .bookmark:   BookmarkListView()
        case .meeting:    MeetingListView()
        case .email:      EmailListView()
        case .connection: ConnectionListView()
        case .file:       FilesListView()
        case .xPost:      XPostListView()
        case .xFollower:  XFollowerListView()
        case .xDm:        XDirectMessageListView()
        case .habit:      HabitListView()
        }
    }

    private var chatSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("⌬ NEURAL DIALOG")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)
                if let active = appState.activeChatSessionId,
                   let session = appState.chatSession(active) {
                    Text("· \(session.title)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textDim)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showingChat = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.Colors.bg1)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.Colors.cyan.opacity(0.2))
                    .frame(height: 1)
            }

            HStack(spacing: 0) {
                ChatHistorySidebar()
                    .environment(appState)
                OttoChatView()
                    .environment(appState)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(Theme.Colors.bg0)
    }

    // MARK: - Undo monitor

    #if os(macOS)
    private func setupUndoMonitor() {
        undoMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers == "z" {
                if let responder = NSApp.keyWindow?.firstResponder as? NSTextView,
                   responder.undoManager?.canUndo == true {
                    return event
                }
                if appState.undoService.canUndo {
                    Task { await appState.undoService.undo() }
                    return nil
                }
            }
            return event
        }
    }

    private func removeUndoMonitor() {
        if let monitor = undoMonitor {
            NSEvent.removeMonitor(monitor)
            undoMonitor = nil
        }
    }
    #endif
}

#Preview {
    MainView()
        .environment(AppState())
}

// MARK: - Otto Logo (legacy, kept so other views that reference it still compile)

struct OttoLogo: View {
    var size: CGFloat = 28

    var body: some View {
        BrandMark(size: size)
    }
}
