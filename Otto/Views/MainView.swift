import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Top-level shell. Lays the app out in the same grid as
/// `otto-redesign-full.html`:
///
///   ┌─────────┬────────────────────┬─────────┐
///   │ sidebar │ topbar (54pt)      │ daily   │
///   │  250pt  ├────────────────────┤ brief   │
///   │         │ stage content      │ 340pt   │
///   │         │                    │ (home)  │
///   └─────────┴────────────────────┴─────────┘
///
/// The sidebar and the briefing rail run full height; the top bar spans only
/// the middle stage. The briefing rail shows on Home when the window is wide
/// enough — every other view goes "solo" (sidebar + stage).
struct MainView: View {
    @Environment(AppState.self) private var appState

    @State private var showingSettings = false
    @State private var showingIntegrations = false
    @State private var showingHome = true
    @State private var showingMap = false
    @State private var showingCreative = false

    #if os(macOS)
    @State private var undoMonitor: Any?
    #endif

    var body: some View {
        ZStack {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    OttoSidebar(
                        showingHome: $showingHome,
                        showingMap: $showingMap,
                        showingCreative: $showingCreative,
                        showingSettings: $showingSettings,
                        showingIntegrations: $showingIntegrations
                    )
                    .frame(width: 250)

                    OttoVerticalDivider()

                    VStack(spacing: 0) {
                        OttoTopBar(
                            title: crumbTitle,
                            isHome: showingHome && !showingMap && !showingCreative
                                && !showingSettings && !showingIntegrations,
                            onSearch: {
                                // Jump to Home and open universal search.
                                showingHome = true
                                showingMap = false
                                showingCreative = false
                                showingSettings = false
                                showingIntegrations = false
                                appState.homeSearchRequested = true
                            }
                        )
                        .frame(height: 54)

                        mainContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if showingHome && !showingMap && !showingCreative
                        && !showingSettings && !showingIntegrations
                        && geo.size.width >= 1180 {
                        OttoVerticalDivider()
                        OttoRightPanel()
                            .frame(width: 340)
                    }
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
        .frame(minWidth: 1000, minHeight: 680)
        .background(OttoBackdrop())
        .alert("Error", isPresented: .constant(appState.errorMessage != nil)) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .onChange(of: appState.locateItemId) { _, itemId in
            // A locate request targets a list view — leave Home/Map so the
            // destination tab (already set by AppState.locate) is visible.
            if itemId != nil {
                showingHome = false
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
            }
        }
        .onChange(of: appState.pendingChatPrompt) { _, prompt in
            // Prompts can arrive from the menu bar / voice path — make sure
            // the chat (Home) is on screen so OttoChatView consumes them.
            if prompt != nil {
                showingHome = true
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
            }
        }
        .onChange(of: appState.pendingOpenChatSessionId) { _, sessionId in
            // Task-run notification tap / Automations history row: open the
            // session in the chat. Home consumes nothing here — selecting the
            // session id is enough for OttoChatView to attach to it.
            if let sessionId {
                showingHome = true
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
                appState.activeChatSessionId = sessionId
                appState.pendingOpenChatSessionId = nil
            }
        }
        .onChange(of: appState.pendingComposerInsert) { _, text in
            // "Use in chat" on a saved prompt — bring the composer on screen;
            // OttoChatView consumes the text into its input field (no send).
            if text != nil {
                showingHome = true
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
            }
        }
        .onChange(of: appState.showVoiceOverlay) { _, shown in
            // Voice mode mirrors its conversation into the chat — bring the
            // chat (Home) on screen so the user sees it stream behind the
            // floating voice panel.
            if shown {
                showingHome = true
                showingMap = false
                showingCreative = false
                showingSettings = false
                showingIntegrations = false
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

    /// The current view's crumb title (mockup .crumb).
    private var crumbTitle: String {
        if showingSettings { return "Settings" }
        if showingIntegrations { return "Integrations" }
        if showingCreative { return "Creative" }
        if showingMap { return "Map" }
        if showingHome { return "Home" }
        if let customTab = appState.customTabs.first(where: { $0.id == appState.selectedCustomTabId }) {
            return customTab.name
        }
        return appState.selectedTab.pluralTitle
    }

    @ViewBuilder
    private var mainContent: some View {
        if showingSettings {
            SettingsView(inline: true)
        } else if showingIntegrations {
            IntegrationsView(inline: true)
        } else if showingCreative {
            CreativeView()
        } else if showingMap {
            MapView()
        } else if showingHome {
            HomeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        // A selected custom tab wins over the built-in switch; assigning
        // `selectedTab` clears the custom selection (didSet in AppState).
        if let customTab = appState.customTabs.first(where: { $0.id == appState.selectedCustomTabId }) {
            CustomTabView(tab: customTab)
        } else {
            builtInListContent
        }
    }

    @ViewBuilder
    private var builtInListContent: some View {
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
        case .automation: AutomationsView()
        }
    }

    // MARK: - Undo monitor

    #if os(macOS)
    private func setupUndoMonitor() {
        undoMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "z" {
                let isRedo = event.modifierFlags.contains(.shift)
                // While ANY text view is editing (including TextField field
                // editors), Cmd+Z belongs to the text system — even when its
                // undo stack is momentarily empty. Falling through here used
                // to turn "undo typing" into "resurrect a deleted note".
                if NSApp.keyWindow?.firstResponder is NSTextView {
                    return event
                }
                // An open note editor's block operations (delete/move/turn
                // into) are undoable even when keyboard focus sits on the
                // editor chrome rather than a text view.
                if let editorUndo = appState.notesEditorUndoManager {
                    if isRedo, editorUndo.canRedo {
                        editorUndo.redo()
                        return nil
                    }
                    if !isRedo, editorUndo.canUndo {
                        editorUndo.undo()
                        return nil
                    }
                }
                if !isRedo, appState.undoService.canUndo {
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
