import SwiftUI

// MARK: - Settings panes

/// Left-rail navigation entries. Each pane renders as a stack of hairline
/// cards on the right; the rail keeps the sheet calm even as sections grow.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case agent
    case voice
    case interface_
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agent:      return "Agent"
        case .voice:      return "Voice"
        case .interface_: return "Interface"
        case .about:      return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .agent:      return "Backend, credentials & model"
        case .voice:      return "Speech, transcription & wake word"
        case .interface_: return "Menu bar & desktop presence"
        case .about:      return "Version & credits"
        }
    }

    var icon: String {
        switch self {
        case .agent:      return "cpu"
        case .voice:      return "waveform"
        case .interface_: return "macwindow"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var selectedPane: SettingsPane = .agent
    @State private var isSaved: Bool = false
    @State private var falApiKey: String = ""
    @State private var showingFalKey: Bool = false
    @State private var selectedVoiceId: String = FalAIService.shared.getVoiceId()
    @State private var claudeModelId: String = AgentService.Claude.getRawModel()
    @State private var codexModelId: String = AgentService.Codex.getRawModel()
    @State private var anthropicApiKeyDraft: String = ""
    @State private var openaiApiKeyDraft: String = ""
    @State private var anthropicApiKeySaved: Bool = ClaudeAuthService.shared.apiKey() != nil
    @State private var openaiApiKeySaved: Bool = CodexAuthService.shared.apiKey() != nil
    @State private var showingAnthropicKey: Bool = false
    @State private var showingOpenaiKey: Bool = false

    // Hermes (local) — install detection + MCP config setup state.
    @State private var hermesBinaryPath: String? = HermesInstallation.binaryPath()
    @State private var hermesConfigMessage: String? = nil
    @State private var hermesConfigIsError: Bool = false

    /// Bound to the same UserDefaults key everything else reads from
    /// (`AgentBackend.defaultsKey`) so a backend switch in Settings flips the
    /// agent immediately for every code path, including voice mode.
    @AppStorage(AgentBackend.defaultsKey) private var rawBackend: String = AgentBackend.claude.rawValue

    /// Interface toggles — read here for binding, owned by OttoApp which
    /// observes the same keys via `@AppStorage` to actually start/stop
    /// the wake-word listener and install/remove the menu-bar item.
    @AppStorage(WakeWordSettings.enabledKey) private var wakeWordEnabled: Bool = WakeWordSettings.defaultEnabled
    @AppStorage(MenuBarSettings.enabledKey) private var menuBarEnabled: Bool = MenuBarSettings.defaultEnabled
    @AppStorage(MeetingDetectionSettings.enabledKey) private var meetingDetectionEnabled: Bool = MeetingDetectionSettings.defaultEnabled
    @AppStorage(ScreenCapturePrivacySettings.enabledKey) private var screenCapturePrivacyEnabled: Bool = ScreenCapturePrivacySettings.defaultEnabled

    private var selectedBackend: AgentBackend {
        AgentBackend(rawValue: rawBackend) ?? .claude
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            return "\(version) (\(build))"
        }
        return version
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            OttoVerticalDivider()

            VStack(spacing: 0) {
                paneHeader

                OttoDivider()

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        switch selectedPane {
                        case .agent:      agentPane
                        case .voice:      voicePane
                        case .interface_: interfacePane
                        case .about:      aboutPane
                        }
                    }
                    .padding(Theme.Spacing.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                OttoDivider()

                footer
            }
        }
        .frame(width: 700, height: 560)
        .background(Theme.Colors.bg0)
        .onAppear {
            if let existingFalKey = UserDefaults.standard.string(forKey: FalAIService.apiKeyDefaultsKey) {
                falApiKey = existingFalKey
            }
            selectedVoiceId = FalAIService.shared.getVoiceId()
            claudeModelId = AgentService.Claude.getRawModel()
            codexModelId = AgentService.Codex.getRawModel()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.text)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: pane.icon)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 18)
                            Text(pane.title)
                                .font(Theme.Typography.body)
                        }
                    }
                    .buttonStyle(SidebarButtonStyle(isSelected: selectedPane == pane))
                }
            }

            Spacer()

            Text("OTTO \(appVersion)")
                .font(Theme.Typography.monoSmall)
                .tracking(Theme.Tracking.wide)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(width: 176)
        .background(Theme.Colors.bg1)
    }

    // MARK: - Header / footer

    private var paneHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedPane.title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.text)
                Text(selectedPane.subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 24, height: 24)
                    .background(Theme.Colors.borderSubtle)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.md) {
            if isSaved {
                StatusChip(icon: "checkmark", text: "Saved", color: Theme.Colors.green)
                    .transition(.opacity)
            }

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
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }

    // MARK: - Agent pane

    private var agentPane: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            // Backend selector — flipping this changes which CLI Otto routes
            // to immediately, for chat and voice both.
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(AgentBackend.allCases) { backend in
                    backendCard(backend)
                }
            }

            switch selectedBackend {
            case .claude: claudeBackendBlock
            case .codex:  codexBackendBlock
            case .hermes: hermesBackendBlock
            }
        }
    }

    private func backendTagline(_ backend: AgentBackend) -> String {
        switch backend {
        case .claude: return "Anthropic's agent CLI"
        case .codex:  return "OpenAI's agent CLI"
        case .hermes: return "Local · on-device"
        }
    }

    private func backendIcon(_ backend: AgentBackend) -> String {
        switch backend {
        case .claude: return "sparkles"
        case .codex:  return "chevron.left.forwardslash.chevron.right"
        case .hermes: return "internaldrive"
        }
    }

    private func backendCard(_ backend: AgentBackend) -> some View {
        let isSelected = selectedBackend == backend
        return Button {
            rawBackend = backend.rawValue
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Image(systemName: backendIcon(backend))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.Colors.accentText : Theme.Colors.textDim)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.accentText)
                        .opacity(isSelected ? 1 : 0)
                }
                Text(backend.displayName)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(isSelected ? Theme.Colors.text : Theme.Colors.textDim)
                Text(backendTagline(backend))
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(isSelected ? Theme.Colors.selectTint : Theme.Colors.bgInput)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(
                        isSelected ? Theme.Colors.cyan.opacity(0.45) : Theme.Colors.border,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    // MARK: - Per-backend blocks

    private var claudeBackendBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SettingsCard(title: "Access") {
                claudeAuthStatusRow

                Text("Otto invokes the `claude` CLI as a subprocess; the CLI manages its own credentials. Optionally paste an Anthropic API key below to bypass CLI login and bill against your API account instead.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SecretField(
                    placeholder: "sk-ant-…",
                    text: $anthropicApiKeyDraft,
                    isRevealed: $showingAnthropicKey
                )

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Save key") {
                        let ok = ClaudeAuthService.shared.setAPIKey(anthropicApiKeyDraft)
                        anthropicApiKeySaved = ok && !anthropicApiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if anthropicApiKeySaved { anthropicApiKeyDraft = "" }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(anthropicApiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if anthropicApiKeySaved {
                        Button("Clear stored key") {
                            ClaudeAuthService.shared.clearAPIKey()
                            anthropicApiKeySaved = false
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    Spacer()
                }

                Text("Billed via your Anthropic API account at console.anthropic.com, not your Claude subscription. Overrides CLI login when set.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Model") {
                HStack(spacing: Theme.Spacing.sm) {
                    SettingsTextField(placeholder: "claude-opus-4-7", text: $claudeModelId)

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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var codexBackendBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SettingsCard(title: "Access") {
                codexAuthStatusRow

                Text("Otto invokes the `codex` CLI as a subprocess; the CLI manages its own credentials. Optionally paste an OpenAI API key below to bypass CLI login and bill against your API account instead.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SecretField(
                    placeholder: "sk-…",
                    text: $openaiApiKeyDraft,
                    isRevealed: $showingOpenaiKey
                )

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Save key") {
                        let ok = CodexAuthService.shared.setAPIKey(openaiApiKeyDraft)
                        openaiApiKeySaved = ok && !openaiApiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if openaiApiKeySaved { openaiApiKeyDraft = "" }
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(openaiApiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if openaiApiKeySaved {
                        Button("Clear stored key") {
                            CodexAuthService.shared.clearAPIKey()
                            openaiApiKeySaved = false
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    Spacer()
                }

                Text("Billed via your OpenAI API account at platform.openai.com, not your ChatGPT subscription. Overrides CLI login when set.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Model") {
                HStack(spacing: Theme.Spacing.sm) {
                    SettingsTextField(placeholder: "gpt-5.5", text: $codexModelId)

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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hermesBackendBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SettingsCard(title: "Installation") {
                Text("Otto runs `hermes acp` as a local subprocess and talks to it over JSON-RPC. Hermes picks its model server-side via `hermes model`. Otto's tools reach Hermes through a local Unix socket — your tokens stay on this Mac.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let binPath = hermesBinaryPath {
                    HStack(spacing: Theme.Spacing.sm) {
                        StatusChip(icon: "checkmark.circle.fill", text: "Hermes detected", color: Theme.Colors.green)
                        Spacer()
                        Button("Refresh") {
                            hermesBinaryPath = HermesInstallation.binaryPath()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    Text(binPath)
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: Theme.Spacing.sm) {
                        StatusChip(icon: "exclamationmark.triangle", text: "Hermes not installed", color: Theme.Colors.amber)
                        Spacer()
                        Button("Refresh") {
                            hermesBinaryPath = HermesInstallation.binaryPath()
                        }
                        .buttonStyle(GhostButtonStyle())
                    }

                    Text("Install with this one-liner in Terminal, then click Refresh:")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    Text("curl -LsSf https://astral.sh/uv/install.sh | sh && uv tool install 'hermes-agent[acp]'")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.text)
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.bgInput)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(Theme.Colors.border, lineWidth: 1)
                        )

                    Text("Then run `hermes setup` once to configure a model provider.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            SettingsCard(title: "Otto tools") {
                Text("Writes the `otto` MCP entry into ~/.hermes/config.yaml so Hermes can reach Otto's local tool socket. Safe to run again — existing config is preserved.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Set up Otto tools") {
                        setupOttoMCPEntry()
                    }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(hermesBinaryPath == nil)

                    Spacer()
                }

                if let msg = hermesConfigMessage {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: hermesConfigIsError
                              ? "exclamationmark.triangle"
                              : "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(hermesConfigIsError ? Theme.Colors.amber : Theme.Colors.green)
                        Text(msg)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(hermesConfigIsError ? Theme.Colors.amber : Theme.Colors.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Voice pane

    private var voicePane: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SettingsCard(title: "fal.ai") {
                Text("Powers voice mode — Wizper for transcription + ElevenLabs v3 for speech. Get your key at fal.ai/dashboard/keys.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                SecretField(
                    placeholder: "Enter fal.ai API key",
                    text: $falApiKey,
                    isRevealed: $showingFalKey
                )

                if FalAIService.shared.hasAPIKey() {
                    StatusChip(icon: "checkmark.circle.fill", text: "Voice mode ready", color: Theme.Colors.green)
                }
            }

            SettingsCard(title: "Voice") {
                Picker("Voice", selection: $selectedVoiceId) {
                    ForEach(FalAIService.presetVoices, id: \.id) { voice in
                        Text(voice.displayName).tag(voice.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Wake-word toggle — gates the background mic that listens for
            // "wake up" while Otto isn't the active app. Off means no
            // background mic at all.
            SettingsCard {
                SettingsToggleRow(
                    title: "Listen for wake word",
                    subtitle: "When Otto is backgrounded, listens for \"wake up\" to bring the app forward. Uses the mic only when triggered by a sharp sound.",
                    isOn: $wakeWordEnabled
                )
            }
        }
    }

    // MARK: - Interface pane

    private var interfacePane: some View {
        SettingsCard {
            SettingsToggleRow(
                title: "Show in menu bar",
                subtitle: "Compact status item alongside the macOS clock — current time + countdown to your next calendar event. Click to bring Otto forward.",
                isOn: $menuBarEnabled
            )

            SettingsToggleRow(
                title: "Detect meetings & offer transcription",
                subtitle: "When another app starts using your microphone (Zoom, Meet, …), Otto shows a floating prompt to transcribe the meeting. Stopping — or leaving the call — turns the transcript into a meeting note, with your action items added to To-dos.",
                isOn: $meetingDetectionEnabled
            )

            SettingsToggleRow(
                title: "Hide Otto while transcribing",
                subtitle: "While a meeting is being transcribed, keep Otto's banner and windows out of screen shares so the other party can't see you're transcribing. Works with browser-based shares (Meet, Zoom/Teams in a tab); a native full-screen recorder on the latest macOS may still capture it.",
                isOn: $screenCapturePrivacyEnabled
            )
        }
    }

    // MARK: - About pane

    private var aboutPane: some View {
        SettingsCard {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.Colors.selectTint)
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.Colors.cyan.opacity(0.3), lineWidth: 1)
                    Text("O")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.accentText)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Otto")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.text)
                    Text("Version \(appVersion)")
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.textDim)
                }
            }

            Text("AI-powered personal knowledge management")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)
        }
    }

    /// Write (or merge) the `otto` MCP server entry into `~/.hermes/config.yaml`
    /// pointing at Otto's actual Unix socket path. Uses a minimal hand-written
    /// merge — read existing YAML lines, drop any old `mcp_servers.otto`
    /// block, append a fresh one. We deliberately don't pull in a YAML
    /// library; the file is small and the edit is local.
    private func setupOttoMCPEntry() {
        hermesConfigMessage = nil
        hermesConfigIsError = false

        guard let socketPath = OttoMCPServer.shared.ensureStarted() else {
            hermesConfigMessage = "Otto MCP server failed to start. Try restarting Otto."
            hermesConfigIsError = true
            return
        }

        let home = NSHomeDirectory()
        let configDir = "\(home)/.hermes"
        let configPath = "\(configDir)/config.yaml"
        do {
            try FileManager.default.createDirectory(
                atPath: configDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        } catch {
            hermesConfigMessage = "Couldn't create ~/.hermes: \(error.localizedDescription)"
            hermesConfigIsError = true
            return
        }

        let existing: String = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let merged = SettingsView.mergeOttoMCPEntry(into: existing, socketPath: socketPath)
        do {
            try merged.write(toFile: configPath, atomically: true, encoding: .utf8)
            hermesConfigMessage = "Wrote `otto` MCP entry → \(configPath)"
            hermesConfigIsError = false
        } catch {
            hermesConfigMessage = "Couldn't write config: \(error.localizedDescription)"
            hermesConfigIsError = true
        }
    }

    /// Pure-function merger so it's easy to reason about (and testable later).
    /// If there's no existing `mcp_servers:` section, appends one with just
    /// the `otto` entry. If there is one, replaces any prior `otto:` child
    /// while leaving other servers (and other keys) untouched.
    static func mergeOttoMCPEntry(into existing: String, socketPath: String) -> String {
        let ottoBlock = """
        mcp_servers:
          otto:
            command: nc
            args:
              - "-U"
              - "\(socketPath)"
        """
        // Quick path: empty/missing file.
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ottoBlock + "\n"
        }

        let lines = existing.components(separatedBy: "\n")
        var out: [String] = []
        var i = 0
        var foundMcp = false
        var insertedOtto = false

        while i < lines.count {
            let line = lines[i]
            if !foundMcp && line.trimmingCharacters(in: .whitespaces).hasPrefix("mcp_servers:") {
                foundMcp = true
                out.append(line)
                i += 1
                // Walk over any indented children, copy non-otto entries,
                // insert our otto block in place of any existing one.
                var copiedOther = false
                while i < lines.count {
                    let child = lines[i]
                    let isBlank = child.trimmingCharacters(in: .whitespaces).isEmpty
                    let isIndented = child.first == " " || child.first == "\t"
                    if !isBlank && !isIndented {
                        break // back to top-level — section ends
                    }
                    // Detect a top-level child of mcp_servers (2-space indent).
                    if child.hasPrefix("  ") && !child.hasPrefix("   ")
                        && child.trimmingCharacters(in: .whitespaces).hasPrefix("otto:") {
                        // Skip the existing otto block (this line + any deeper-indented continuation).
                        i += 1
                        while i < lines.count {
                            let cont = lines[i]
                            if cont.trimmingCharacters(in: .whitespaces).isEmpty {
                                i += 1; continue
                            }
                            if cont.hasPrefix("    ") { i += 1; continue }
                            break
                        }
                        continue
                    }
                    out.append(child)
                    if !isBlank { copiedOther = true }
                    i += 1
                }
                // Now insert our fresh otto block, indented properly.
                out.append("  otto:")
                out.append("    command: nc")
                out.append("    args:")
                out.append("      - \"-U\"")
                out.append("      - \"\(socketPath)\"")
                insertedOtto = true
                _ = copiedOther // silence warning
                continue
            }
            out.append(line)
            i += 1
        }

        if !foundMcp {
            // No existing mcp_servers — append a fresh block.
            if !out.last!.isEmpty { out.append("") }
            out.append(ottoBlock)
        }
        _ = insertedOtto
        return out.joined(separator: "\n")
    }

    // MARK: - Auth status rows

    @ViewBuilder
    private var claudeAuthStatusRow: some View {
        switch ClaudeAuthService.shared.effectiveAuthMode() {
        case .apiKey:
            StatusChip(icon: "key.fill", text: "Using stored Anthropic API key", color: Theme.Colors.violet)
        case .cliLogin:
            StatusChip(icon: "checkmark.circle.fill", text: "Connected via Claude Code CLI", color: Theme.Colors.green)
        case .none:
            StatusChip(icon: "exclamationmark.triangle", text: "Not signed in — run `claude` in Terminal, or paste an API key", color: Theme.Colors.amber)
        }
    }

    @ViewBuilder
    private var codexAuthStatusRow: some View {
        switch CodexAuthService.shared.effectiveAuthMode() {
        case .apiKey:
            StatusChip(icon: "key.fill", text: "Using stored OpenAI API key", color: Theme.Colors.violet)
        case .cliLogin:
            StatusChip(icon: "checkmark.circle.fill", text: "Connected via Codex CLI", color: Theme.Colors.green)
        case .none:
            StatusChip(icon: "exclamationmark.triangle", text: "Not signed in — run `codex login` in Terminal, or paste an API key", color: Theme.Colors.amber)
        }
    }
}

// MARK: - Settings primitives

/// Hairline card — mono uppercase label header + content on a panel surface.
private struct SettingsCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let title {
                Text(title)
                    .hudLabel()
            }
            content()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.panel)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.xl)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }
}

/// Capsule status chip — tinted background, hairline stroke.
private struct StatusChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(Theme.Typography.caption)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.10)))
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 1))
    }
}

/// Secret input with a reveal toggle. Keys are data → monospace.
private struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isRevealed: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.Typography.monoCaption)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 9)
        .background(Theme.Colors.bgInput)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
    }
}

/// Plain bordered text input matching SecretField's metrics. Model ids are
/// data → monospace.
private struct SettingsTextField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Typography.monoCaption)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 9)
            .background(Theme.Colors.bgInput)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Theme.Colors.border, lineWidth: 1)
            )
    }
}

/// Switch row — title + wrapping subtitle on the left, accent switch on the
/// right, vertically centered.
private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)
                Text(subtitle)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.Colors.cyan)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
