import SwiftUI

/// Settings → Agent card surfacing the on-device semantic index: what phase
/// it's in, how many passages are searchable, and when it last caught up.
/// Read-only — the index maintains itself from the persistence-revision
/// watcher; this exists so a fresh install's first long pass is explained.
struct SemanticIndexSettingsCard: View {
    private var status = SemanticIndexStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("SEMANTIC SEARCH")
                .hudLabel()

            Text("On-device meaning-based index over everything Otto stores (meetings, emails, notes, people, posts…). Powers the agent's semantic_search tool. Embeddings are computed locally with Apple's language models — nothing leaves this Mac.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.textDim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Spacing.sm) {
                statusDot
                Text(status.summaryLine)
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.textDim)
                Spacer()
                if let completed = status.lastCompleted {
                    Text("updated \(completed.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Typography.monoSmall)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
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

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 7, height: 7)
    }

    private var dotColor: Color {
        switch status.phase {
        case .ready: return Theme.Colors.green
        case .indexing, .preparing: return Theme.Colors.amber
        case .idle: return Theme.Colors.textDim
        case .unavailable: return Theme.Colors.red
        }
    }
}
