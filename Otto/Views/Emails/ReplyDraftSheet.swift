import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Editable reply draft for one email — the output surface of
/// `ReplyDraftService`. Gmail stays read-only, so the actions are
/// clipboard + deep link: copy the draft, jump to the thread in Gmail,
/// paste into the real reply box (threading preserved).
struct ReplyDraftSheet: View {
    let email: Email
    let onClose: () -> Void

    @Environment(AppState.self) private var appState
    private var service: ReplyDraftService { .shared }

    @State private var draftText: String = ""
    @State private var didHydrate = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()
            content
        }
        .frame(minWidth: 520, minHeight: 420)
        .background(Theme.Colors.bg0)
        .onChange(of: service.phase) { _, phase in
            if case .ready(let text) = phase, !didHydrate {
                draftText = text
                didHydrate = true
            }
        }
        .onAppear {
            if case .ready(let text) = service.phase, !didHydrate {
                draftText = text
                didHydrate = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.accentText)
            VStack(alignment: .leading, spacing: 1) {
                Text("Reply draft")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)
                Text("Re: \(email.subject.isEmpty ? email.preview : email.subject) — \(email.displaySender)")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.textDim)
                    .lineLimit(1)
            }
            Spacer()
            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.Colors.bg1)
    }

    @ViewBuilder
    private var content: some View {
        switch service.phase {
        case .idle, .generating:
            VStack(spacing: 10) {
                ProgressView()
                Text("Drafting in your voice…")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.Colors.amber)
                Text(message)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Try again") {
                    didHydrate = false
                    service.beginDraft(for: email, appState: appState)
                }
                .buttonStyle(AccentButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $draftText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Theme.Colors.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
                    .frame(maxHeight: .infinity)

                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        didHydrate = false
                        service.beginDraft(for: email, appState: appState)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 10))
                            Text("Redraft").font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        markHandled()
                    } label: {
                        Text("Dismiss from queue")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Colors.textDim)
                    }
                    .buttonStyle(.plain)

                    Button {
                        copyDraft()
                    } label: {
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(AccentButtonStyle())

                    Button {
                        copyDraft()
                        if let url = EmailTriageService.gmailThreadURL(for: email) {
                            #if os(macOS)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                        markHandled()
                        onClose()
                    } label: {
                        Text("Copy & open Gmail")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(AccentButtonStyle())
                }
            }
            .padding(16)
        }
    }

    private func copyDraft() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draftText, forType: .string)
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    /// Clear the thread from the needs-reply queue (the user has acted).
    private func markHandled() {
        guard var live = appState.emails.first(where: { $0.id == email.id }) else { return }
        live.needsReplyDismissedAt = Date()
        Task { await appState.updateEmail(live) }
    }
}
