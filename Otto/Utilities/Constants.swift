import SwiftUI

enum DefaultTags {
    static let domain: [DomainTag] = [
        DomainTag(name: "AI", isDefault: true),
        DomainTag(name: "Ops", isDefault: true),
        DomainTag(name: "Marketing", isDefault: true),
        DomainTag(name: "Finance", isDefault: true),
        DomainTag(name: "Health", isDefault: true),
        DomainTag(name: "Learning", isDefault: true),
        DomainTag(name: "Creative", isDefault: true),
        DomainTag(name: "Technical", isDefault: true),
        DomainTag(name: "Communication", isDefault: true),
        DomainTag(name: "Planning", isDefault: true),
        DomainTag(name: "Research", isDefault: true),
        DomainTag(name: "Design", isDefault: true),
    ]
}

enum AppColors {
    static let primary = Color.blue
    static let secondary = Color.gray
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red

    static let todoBackground = Color.blue.opacity(0.1)
    static let noteBackground = Color.green.opacity(0.1)
    static let ideaBackground = Color.purple.opacity(0.1)
    static let reminderBackground = Color.orange.opacity(0.1)
}
