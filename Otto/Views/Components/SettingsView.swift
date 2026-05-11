import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var isSaved: Bool = false
    @State private var falApiKey: String = ""
    @State private var showingFalKey: Bool = false
    @State private var selectedVoiceId: String = FalAIService.shared.getVoiceId()
    @State private var claudeModelId: String = AgentService.Claude.getRawModel()
    @State private var codexModelId: String = AgentService.Codex.getRawModel()
    @State private var isRefreshingToken: Bool = false
    @State private var refreshResultMessage: String?
    @State private var refreshResultIsError: Bool = false

    /// Bound to the same UserDefaults key everything else reads from
    /// (`AgentBackend.defaultsKey`) so a backend switch in Settings flips the
    /// agent immediately for every code path, including voice mode.
    @AppStorage(AgentBackend.defaultsKey) private var rawBackend: String = AgentBackend.claude.rawValue

    private var selectedBackend: AgentBackend {
        get { AgentBackend(rawValue: rawBackend) ?? .claude }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(Theme.Typography.title)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(width: 24, height: 24)
                        .background(Theme.Colors.borderSubtle)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(Theme.Spacing.xl)

            OttoDivider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    // Agent (Backend + per-backend auth/model) Section
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.cyan)
                        Text("Agent")
                            .font(Theme.Typography.headline)
                    }

                    // Backend picker — flipping this changes which CLI Otto
                    // routes to immediately, for chat and voice both.
                    Picker("Backend", selection: $rawBackend) {
                        ForEach(AgentBackend.allCases) { b in
                            Text(b.displayName).tag(b.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: rawBackend) { _, _ in
                        // Don't carry a "Token refreshed" message from the
                        // other backend onto this panel — different auth
                        // file, different action.
                        refreshResultMessage = nil
                    }

                    if selectedBackend == .claude {
                        claudeBackendBlock
                    } else {
                        codexBackendBlock
                    }

                    if isSaved {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                            Text("Saved!")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.personal)
                        .transition(.opacity)
                    }
                }

                OttoDivider()

                // Voice Mode (fal.ai) Section
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.aiAccent)
                        Text("Voice Mode (fal.ai)")
                            .font(Theme.Typography.headline)
                    }

                    Text("Powers voice mode — Wizper for transcription + ElevenLabs v3 for speech. Get your key at fal.ai/dashboard/keys.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    // API key input
                    HStack(spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.sm) {
                            if showingFalKey {
                                TextField("Enter fal.ai API key", text: $falApiKey)
                                    .textFieldStyle(.plain)
                                    .font(Theme.Typography.body)
                            } else {
                                SecureField("Enter fal.ai API key", text: $falApiKey)
                                    .textFieldStyle(.plain)
                                    .font(Theme.Typography.body)
                            }

                            Button {
                                showingFalKey.toggle()
                            } label: {
                                Image(systemName: showingFalKey ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.Colors.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Theme.Colors.borderSubtle.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .strokeBorder(Theme.Colors.hoverTint, lineWidth: 1)
                        )
                    }

                    // Status indicator
                    if FalAIService.shared.hasAPIKey() {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.Colors.aiAccent)
                            Text("Voice mode ready")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.aiAccent)
                        }
                    }

                    // Voice picker
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Voice")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)

                        Picker("Voice", selection: $selectedVoiceId) {
                            ForEach(FalAIService.presetVoices, id: \.id) { voice in
                                Text(voice.displayName).tag(voice.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .padding(.top, Theme.Spacing.xs)
                }

                OttoDivider()

                // About Section
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "brain")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.accent)
                        Text("About Otto")
                            .font(Theme.Typography.headline)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Version 1.0.0")
                            .font(Theme.Typography.body)
                        Text("AI-powered personal knowledge management")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                }
                }
                .padding(Theme.Spacing.xl)
            }

            OttoDivider()

            // Footer buttons
            HStack(spacing: Theme.Spacing.md) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(GhostButtonStyle())

                Button("Save") {
                    if !falApiKey.isEmpty {
                        FalAIService.shared.setAPIKey(falApiKey)
                    }
                    FalAIService.shared.setVoiceId(selectedVoiceId)
                    AgentService.Claude.setModel(claudeModelId)
                    AgentService.Codex.setModel(codexModelId)

                    withAnimation {
                        isSaved = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
                .buttonStyle(AccentButtonStyle())
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 420)
        .frame(minHeight: 400, maxHeight: 700)
        .background(Theme.Colors.background)
        .onAppear {
            if let existingFalKey = UserDefaults.standard.string(forKey: FalAIService.apiKeyDefaultsKey) {
                falApiKey = existingFalKey
            }
            selectedVoiceId = FalAIService.shared.getVoiceId()
            claudeModelId = AgentService.Claude.getRawModel()
            codexModelId = AgentService.Codex.getRawModel()
        }
    }

    // MARK: - Per-backend blocks

    private var claudeBackendBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Otto uses your Claude Code credentials for AI features. Sign in via the Claude Code CLI to enable Ask.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)

            if ClaudeAuthService.shared.isSignedIn() {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.purple)
                    Text("Connected — using Claude Code credentials")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.purple)
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("Not signed in — run `claude` in Terminal")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Refresh token button — useful after upgrading/changing plan
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    Task { await refreshClaudeToken() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if isRefreshingToken {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text(isRefreshingToken ? "Refreshing…" : "Refresh token")
                            .font(Theme.Typography.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(isRefreshingToken || !ClaudeAuthService.shared.isSignedIn())

                if let msg = refreshResultMessage {
                    Text(msg)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(refreshResultIsError ? .orange : Theme.Colors.personal)
                }

                Spacer()
            }
            .padding(.top, Theme.Spacing.xs)

            // Model picker
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Model")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                HStack(spacing: Theme.Spacing.sm) {
                    TextField("claude-opus-4-7", text: $claudeModelId)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Theme.Colors.borderSubtle.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .strokeBorder(Theme.Colors.hoverTint, lineWidth: 1)
                        )

                    Menu {
                        ForEach(AgentService.Claude.presetModels, id: \.self) { preset in
                            Button(preset) { claudeModelId = preset }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text("Enter any Anthropic model ID. Append `[1m]` to opt into the 1M-token context window. Presets: \(AgentService.Claude.presetModels.joined(separator: ", ")).")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    private var codexBackendBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Otto uses your Codex credentials for AI features. Sign in via the Codex app (or `codex login` in Terminal) to enable Ask.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)

            if CodexAuthService.shared.isSignedIn() {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Colors.cyan)
                    Text("Connected — using Codex credentials")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.cyan)
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text("Not signed in — open the Codex app or run `codex login`")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.orange)
                }
            }

            // Refresh token button — useful after upgrading/changing plan,
            // same role as Claude's button next to it on the other tab.
            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    Task { await refreshCodexToken() }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        if isRefreshingToken {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        Text(isRefreshingToken ? "Refreshing…" : "Refresh token")
                            .font(Theme.Typography.caption)
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(isRefreshingToken || !CodexAuthService.shared.isSignedIn())

                if let msg = refreshResultMessage {
                    Text(msg)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(refreshResultIsError ? .orange : Theme.Colors.personal)
                }

                Spacer()
            }
            .padding(.top, Theme.Spacing.xs)

            // Model picker
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Model")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                HStack(spacing: Theme.Spacing.sm) {
                    TextField("gpt-5.5", text: $codexModelId)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(Theme.Colors.borderSubtle.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .strokeBorder(Theme.Colors.hoverTint, lineWidth: 1)
                        )

                    Menu {
                        ForEach(AgentService.Codex.presetModels, id: \.self) { preset in
                            Button(preset) { codexModelId = preset }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Text("Enter any Codex model ID. Presets: \(AgentService.Codex.presetModels.joined(separator: ", ")).")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.top, Theme.Spacing.xs)
        }
    }

    @MainActor
    private func refreshClaudeToken() async {
        isRefreshingToken = true
        refreshResultMessage = nil
        defer { isRefreshingToken = false }
        do {
            _ = try await ClaudeAuthService.shared.refreshAccessToken()
            refreshResultMessage = "Token refreshed"
            refreshResultIsError = false
        } catch {
            refreshResultMessage = error.localizedDescription
            refreshResultIsError = true
        }
    }

    @MainActor
    private func refreshCodexToken() async {
        isRefreshingToken = true
        refreshResultMessage = nil
        defer { isRefreshingToken = false }
        do {
            _ = try await CodexAuthService.shared.refreshAccessToken()
            refreshResultMessage = "Token refreshed"
            refreshResultIsError = false
        } catch {
            refreshResultMessage = error.localizedDescription
            refreshResultIsError = true
        }
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

}

#Preview {
    SettingsView()
        .environment(AppState())
}
