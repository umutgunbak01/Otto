import SwiftUI

struct ConvertTypeMenu: View {
    let currentType: ContentType
    let onConvert: (ContentType) -> Void

    var body: some View {
        Menu {
            ForEach(ContentType.allCases) { type in
                if type != currentType {
                    Button {
                        onConvert(type)
                    } label: {
                        Label(type.displayName, systemImage: type.iconName)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                Text("Convert")
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(Theme.Colors.secondaryText)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Colors.borderSubtle)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

// Compact version for row views (icon only)
struct ConvertTypeMenuCompact: View {
    let currentType: ContentType
    let onConvert: (ContentType) -> Void

    var body: some View {
        Menu {
            Text("Convert to...")
                .font(Theme.Typography.caption)

            Divider()

            ForEach(ContentType.allCases) { type in
                if type != currentType {
                    Button {
                        onConvert(type)
                    } label: {
                        Label(type.displayName, systemImage: type.iconName)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.secondaryText)
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }
}

#Preview {
    VStack(spacing: Theme.Spacing.lg) {
        HStack {
            Text("Full menu:")
            ConvertTypeMenu(currentType: .note) { newType in
                print("Convert to \(newType)")
            }
        }

        HStack {
            Text("Compact menu:")
            ConvertTypeMenuCompact(currentType: .todo) { newType in
                print("Convert to \(newType)")
            }
        }
    }
    .padding()
}
