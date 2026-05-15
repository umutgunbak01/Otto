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

                    switch selectedBackend {
                    case .claude: claudeBackendBlock
                    case .codex:  codexBackendBlock
                    case .hermes: hermesBackendBlock
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

                    // Wake-word toggle — gates the background mic that
                    // listens for "wake up" while Otto isn't the active
                    // app. Off means no background mic at all.
                    Toggle(isOn: $wakeWordEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Listen for wake word")
                                .font(Theme.Typography.body)
                            Text("When Otto is backgrounded, listens for \"wake up\" to bring the app forward. Uses the mic only when triggered by a sharp sound.")
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.top, Theme.Spacing.sm)
                }

                OttoDivider()

                // Interface (menu bar)
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.Colors.cyan)
                        Text("Interface")
                            .font(Theme.Typography.headline)
                    }

                    Toggle(isOn: $menuBarEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show in menu bar")
                                .font(Theme.Typography.body)
                            Text("Compact status item alongside the macOS clock — current time + countdown to your next calendar event. Click to bring Otto forward.")
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                        }
                    }
                    .toggleStyle(.switch)
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
            Text("Otto invokes the `claude` CLI as a subprocess; the CLI manages its own credentials. Optionally paste an Anthropic API key below to bypass CLI login and bill against your API account instead.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)

            claudeAuthStatusRow

            // API key (optional) — overrides CLI login when set.
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Anthropic API key (optional)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                HStack(spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        if showingAnthropicKey {
                            TextField("sk-ant-…", text: $anthropicApiKeyDraft)
                                .textFieldStyle(.plain)
                                .font(Theme.Typography.body)
                        } else {
                            SecureField("sk-ant-…", text: $anthropicApiKeyDraft)
                                .textFieldStyle(.plain)
                                .font(Theme.Typography.body)
                        }
                        Button {
                            showingAnthropicKey.toggle()
                        } label: {
                            Image(systemName: showingAnthropicKey ? "eye.slash" : "eye")
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
            Text("Otto invokes the `codex` CLI as a subprocess; the CLI manages its own credentials. Optionally paste an OpenAI API key below to bypass CLI login and bill against your API account instead.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)

            codexAuthStatusRow

            // API key (optional) — overrides CLI login when set.
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("OpenAI API key (optional)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)

                HStack(spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        if showingOpenaiKey {
                            TextField("sk-…", text: $openaiApiKeyDraft)
                                .textFieldStyle(.plain)
                                .font(Theme.Typography.body)
                        } else {
                            SecureField("sk-…", text: $openaiApiKeyDraft)
                                .textFieldStyle(.plain)
                                .font(Theme.Typography.body)
                        }
                        Button {
                            showingOpenaiKey.toggle()
                        } label: {
                            Image(systemName: showingOpenaiKey ? "eye.slash" : "eye")
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

    private var hermesBackendBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Otto runs `hermes acp` as a local subprocess and talks to it over JSON-RPC. Hermes picks its model server-side via `hermes model`. Otto's tools reach Hermes through a local Unix socket — your tokens stay on this Mac.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.secondaryText)

            // Install status row
            if let binPath = hermesBinaryPath {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.cyan)
                    Text("Hermes detected at \(binPath)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.cyan)
                    Spacer()
                    Button("Refresh") {
                        hermesBinaryPath = HermesInstallation.binaryPath()
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Colors.amber)
                        Text("Hermes not installed")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.amber)
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
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.text)
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.borderSubtle.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    Text("Then run `hermes setup` once to configure a model provider.")
                        .font(Theme.Typography.small)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }

            // Set up Otto tools button — writes/updates the `otto` MCP entry
            // in ~/.hermes/config.yaml so Hermes knows how to reach Otto's
            // local MCP socket. Idempotent.
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
                        .foregroundStyle(hermesConfigIsError ? Theme.Colors.amber : Theme.Colors.cyan)
                    Text(msg)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(hermesConfigIsError ? Theme.Colors.amber : Theme.Colors.cyan)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        let mode = ClaudeAuthService.shared.effectiveAuthMode()
        switch mode {
        case .apiKey:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                Text("Using stored Anthropic API key")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.purple)
            }
        case .cliLogin:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.purple)
                Text("Connected via Claude Code CLI")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.purple)
            }
        case .none:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("Not signed in — run `claude` in Terminal, or paste an API key below")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var codexAuthStatusRow: some View {
        let mode = CodexAuthService.shared.effectiveAuthMode()
        switch mode {
        case .apiKey:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.cyan)
                Text("Using stored OpenAI API key")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.cyan)
            }
        case .cliLogin:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.cyan)
                Text("Connected via Codex CLI")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.cyan)
            }
        case .none:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                Text("Not signed in — run `codex login` in Terminal, or paste an API key below")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
