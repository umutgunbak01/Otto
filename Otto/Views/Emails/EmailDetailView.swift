import SwiftUI

// MARK: - Email Body View

/// Renders email body content with proper formatting: tappable links, bullet points, paragraphs
private struct EmailBodyView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(Array(parseParagraphs().enumerated()), id: \.offset) { _, paragraph in
                paragraphView(paragraph)
            }
        }
    }

    private enum ParagraphElement {
        case text(String)
        case bulletPoint(String)
        case heading(String)
    }

    private func parseParagraphs() -> [ParagraphElement] {
        let lines = text.components(separatedBy: "\n")
        var elements: [ParagraphElement] = []
        var currentParagraph: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // Flush current paragraph
                if !currentParagraph.isEmpty {
                    elements.append(.text(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                continue
            }

            // Headings
            if trimmed.hasPrefix("### ") || trimmed.hasPrefix("## ") || trimmed.hasPrefix("# ") {
                if !currentParagraph.isEmpty {
                    elements.append(.text(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                let headerText = trimmed.replacingOccurrences(of: "^#{1,3}\\s+", with: "", options: .regularExpression)
                elements.append(.heading(headerText))
            }
            // Bold header line
            else if trimmed.hasPrefix("**") && trimmed.hasSuffix("**") && trimmed.count > 4 {
                if !currentParagraph.isEmpty {
                    elements.append(.text(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                let headerText = String(trimmed.dropFirst(2).dropLast(2))
                elements.append(.heading(headerText))
            }
            // Bullet points: -, *, •
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ") {
                if !currentParagraph.isEmpty {
                    elements.append(.text(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                elements.append(.bulletPoint(String(trimmed.dropFirst(2))))
            }
            else if trimmed.hasPrefix("* ") && !(trimmed.hasSuffix("*") && !trimmed.hasSuffix("**")) {
                if !currentParagraph.isEmpty {
                    elements.append(.text(currentParagraph.joined(separator: "\n")))
                    currentParagraph = []
                }
                elements.append(.bulletPoint(String(trimmed.dropFirst(2))))
            }
            // Regular text — accumulate into paragraph
            else {
                currentParagraph.append(trimmed)
            }
        }

        // Flush remaining
        if !currentParagraph.isEmpty {
            elements.append(.text(currentParagraph.joined(separator: "\n")))
        }

        return elements
    }

    @ViewBuilder
    private func paragraphView(_ element: ParagraphElement) -> some View {
        switch element {
        case .heading(let text):
            richText(text)
                .font(Theme.Typography.headline)
                .padding(.top, Theme.Spacing.xs)

        case .bulletPoint(let text):
            HStack(alignment: .top, spacing: Theme.Spacing.xs) {
                Text("\u{2022}")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                richText(text)
                    .font(Theme.Typography.body)
            }
            .padding(.leading, Theme.Spacing.sm)

        case .text(let text):
            richText(text)
                .font(Theme.Typography.body)
        }
    }

    /// Renders text with inline markdown (bold, italic, links) as an AttributedString
    private func richText(_ input: String) -> Text {
        // Convert [text](url) markdown links to tappable attributed string
        if let attributed = try? AttributedString(markdown: input, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
                .foregroundColor(Theme.Colors.text)
        }
        return Text(input)
            .foregroundColor(Theme.Colors.text)
    }
}

// MARK: - Email Detail View

struct EmailDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let email: Email

    @State private var showingDeleteAlert = false

    /// All emails in the same thread, sorted chronologically
    private var threadEmails: [Email] {
        let thread = appState.emails
            .filter { $0.threadId == email.threadId }
            .sorted { $0.receivedDate < $1.receivedDate }
        // Only show thread chain if there are multiple emails
        return thread.count > 1 ? thread : []
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            OttoDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if threadEmails.isEmpty {
                        // Single email — no thread
                        singleEmailView(email: email)
                    } else {
                        // Thread chain
                        threadChainView
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
            }
        }
        #if os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        #else
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .alert("Delete Email?", isPresented: $showingDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deleteEmails([email.id])
                    dismiss()
                }
            }
        } message: {
            Text("This will permanently delete this email. This action cannot be undone.")
        }
        .task {
            // Mark as read when opened
            if !email.isRead {
                var updated = email
                updated.isRead = true
                await appState.updateEmail(updated)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            // Back button
            Button {
                dismiss()
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                    Text("Back")
                        .font(Theme.Typography.body)
                }
                .foregroundStyle(Theme.Colors.accent)
            }
            .buttonStyle(.plain)

            Spacer()

            // Subject as title
            Text(email.subject)
                .font(Theme.Typography.title)
                .lineLimit(1)

            Spacer()

            // Actions
            HStack(spacing: Theme.Spacing.md) {
                // Labels
                if !email.labels.isEmpty {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(email.labels.filter { !$0.hasPrefix("CATEGORY_") && $0 != "UNREAD" }.prefix(3), id: \.self) { label in
                            Text(label.capitalized)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, 2)
                                .background(Theme.Colors.accent.opacity(0.1))
                                .foregroundStyle(Theme.Colors.accent)
                                .clipShape(Capsule())
                        }
                    }
                }

                // Thread count badge
                if threadEmails.count > 1 {
                    Text("\(threadEmails.count) messages")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.borderSubtle)
                        .clipShape(Capsule())
                }

                // More menu
                Menu {
                    Button {
                        Task {
                            var updated = email
                            updated.isRead.toggle()
                            await appState.updateEmail(updated)
                        }
                    } label: {
                        Label(email.isRead ? "Mark as Unread" : "Mark as Read",
                              systemImage: email.isRead ? "envelope.badge" : "envelope.open")
                    }

                    Button {
                        Task { await appState.addBlockedSender(email.sender) }
                    } label: {
                        Label("Block Sender", systemImage: "hand.raised")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showingDeleteAlert = true
                    } label: {
                        Label("Delete Email", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Single Email View

    private func singleEmailView(email: Email) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Sender row with avatar
            senderRow(email: email)

            // Recipients
            if !email.recipients.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    Text("To:")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                    Text(email.recipients.joined(separator: ", "))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .lineLimit(2)
                }
                .padding(.leading, 52) // Align with text after avatar
            }

            OttoDivider()

            // Email body
            EmailBodyView(text: email.body)
                .textSelection(.enabled)
        }
    }

    // MARK: - Thread Chain View

    private var threadChainView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(threadEmails.enumerated()), id: \.element.id) { index, threadEmail in
                ThreadEmailCard(
                    email: threadEmail,
                    isExpanded: threadEmail.id == email.id || index == threadEmails.count - 1
                )

                if index < threadEmails.count - 1 {
                    // Thread connector line
                    HStack {
                        Rectangle()
                            .fill(Theme.Colors.accent.opacity(0.2))
                            .frame(width: 2, height: 16)
                            .padding(.leading, 19) // Center under avatar
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Sender Row

    private func senderRow(email: Email) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            // Avatar
            senderAvatar(for: email)

            // Sender info
            VStack(alignment: .leading, spacing: 2) {
                Text(email.displaySender)
                    .font(Theme.Typography.headline)

                Text(email.sender)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()

            // Date
            Text(fullFormattedDate(email.receivedDate))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    // MARK: - Sender Avatar

    private func senderAvatar(for email: Email) -> some View {
        let initial = String((email.senderName ?? email.sender).prefix(1)).uppercased()
        let color = avatarColor(for: email.sender)

        return Circle()
            .fill(color.opacity(0.15))
            .frame(width: 40, height: 40)
            .overlay {
                Text(initial)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }
    }

    // MARK: - Helpers

    private func fullFormattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func avatarColor(for email: String) -> Color {
        let hash = abs(email.hashValue)
        let colors: [Color] = [
            .blue, .purple, .green, .orange, .pink, .teal, .indigo, .mint
        ]
        return colors[hash % colors.count]
    }
}

// MARK: - Thread Email Card

private struct ThreadEmailCard: View {
    @Environment(AppState.self) private var appState
    let email: Email
    let isExpanded: Bool

    @State private var localExpanded: Bool

    init(email: Email, isExpanded: Bool) {
        self.email = email
        self.isExpanded = isExpanded
        self._localExpanded = State(initialValue: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible, tappable to expand/collapse
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    localExpanded.toggle()
                }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    // Avatar
                    senderAvatar

                    // Sender info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email.displaySender)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.text)

                        if !localExpanded {
                            Text(email.snippet.isEmpty ? String(email.body.prefix(100)) : email.snippet)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                                .lineLimit(1)
                        } else {
                            Text(email.sender)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                    }

                    Spacer()

                    // Date
                    Text(compactDate(email.receivedDate))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)

                    // Expand/collapse indicator
                    Image(systemName: localExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(Theme.Spacing.md)
            }
            .buttonStyle(.plain)

            // Body — only when expanded
            if localExpanded {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    // Recipients
                    if !email.recipients.isEmpty {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text("To:")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.tertiaryText)
                            Text(email.recipients.joined(separator: ", "))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .lineLimit(2)
                        }
                    }

                    OttoDivider()

                    EmailBodyView(text: email.body)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.bottom, Theme.Spacing.md)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(localExpanded ? Theme.Colors.borderSubtle.opacity(0.5) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(localExpanded ? Theme.Colors.hoverTint : Theme.Colors.borderSubtle.opacity(0.5), lineWidth: 1)
        )
    }

    private var senderAvatar: some View {
        let initial = String((email.senderName ?? email.sender).prefix(1)).uppercased()
        let color = avatarColor(for: email.sender)

        return Circle()
            .fill(color.opacity(0.15))
            .frame(width: 36, height: 36)
            .overlay {
                Text(initial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
            }
    }

    private func compactDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d, h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy"
        }

        return formatter.string(from: date)
    }

    private func avatarColor(for email: String) -> Color {
        let hash = abs(email.hashValue)
        let colors: [Color] = [
            .blue, .purple, .green, .orange, .pink, .teal, .indigo, .mint
        ]
        return colors[hash % colors.count]
    }
}

#Preview {
    EmailDetailView(
        email: Email(
            gmailId: "1",
            threadId: "t1",
            subject: "Meeting Tomorrow at the Office",
            sender: "john.doe@example.com",
            senderName: "John Doe",
            recipients: ["you@example.com", "team@example.com"],
            body: """
            Hi there,

            Just wanted to confirm our meeting tomorrow at 2pm in the main conference room.

            **Agenda:**
            - Project updates
            - Q1 planning
            - Team assignments

            Let me know if you have any questions.

            Best,
            John
            """,
            receivedDate: Date(),
            isRead: false,
            labels: ["INBOX", "IMPORTANT"],
            snippet: "Just wanted to confirm our meeting tomorrow at 2pm."
        )
    )
    .environment(AppState())
    .frame(width: 700, height: 600)
}
