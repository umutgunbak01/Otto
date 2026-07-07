import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Top-level shell. Lays the app out in the same grid as
/// `otto-redesign-mockup.html`:
///
///   ┌──────────────────────────────┐  topbar (48pt, full width)
///   ├─────────┬────────────────────┤
///   │ sidebar │ content            │  body
///   │  224pt  │                    │
///   └─────────┴────────────────────┘
///
/// `content` swaps between Home (chat + right panel), the Map, and the
/// individual list views depending on the sidebar selection.
struct MainView: View {
    @Environment(AppState.self) private var appState

    @State private var showingSettings = false
    @State private var showingIntegrations = false
    @State private var showingHome = true
    @State private var showingMap = false

    #if os(macOS)
    @State private var undoMonitor: Any?
    #endif

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                OttoTopBar(onSearch: {
                    // Jump to Home and open universal search.
                    showingHome = true
                    showingMap = false
                    appState.homeSearchRequested = true
                })
                .frame(height: 48)

                HStack(spacing: 0) {
                    OttoSidebar(
                        showingHome: $showingHome,
                        showingMap: $showingMap,
                        showingSettings: $showingSettings,
                        showingIntegrations: $showingIntegrations
                    )
                    .frame(width: 224)

                    mainContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
                    .padding(.bottom, 32)
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
        .onChange(of: appState.pendingChatPrompt) { _, prompt in
            // Prompts can arrive from the menu bar / voice path — make sure
            // the chat (Home) is on screen so OttoChatView consumes them.
            if prompt != nil {
                showingHome = true
                showingMap = false
            }
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
            // Refresh every connected integration on open so the cached data
            // we just loaded is brought up to date automatically. Throttled
            // internally so reopening the window doesn't re-hammer the APIs.
            appState.syncConnectedIntegrations()
        }
        #if os(macOS)
        .onAppear { setupUndoMonitor() }
        .onDisappear { removeUndoMonitor() }
        #endif
    }

    // MARK: - Main content area

    @ViewBuilder
    private var mainContent: some View {
        if showingMap {
            MapView()
                .background(Theme.Colors.bg0)
        } else if showingHome {
            homeContent
        } else {
            listContent
                .background(Theme.Colors.bg0)
        }
    }

    /// Home — chat column plus the right panel (hidden on compact widths),
    /// mirroring the mockup's `#view-home` grid.
    private var homeContent: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                HomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if geo.size.width >= 1000 {
                    OttoRightPanel()
                        .frame(width: 276)
                }
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
        case .networkHub: NetworkHubListView()
        case .company:    CompanyListView()
        case .event:      EventListView()
        case .community:  CommunityListView()
        case .file:       FilesListView()
        case .xPost:      XPostListView()
        case .xFollower:  XFollowerListView()
        case .xDm:        XDirectMessageListView()
        case .habit:      HabitListView()
        }
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
