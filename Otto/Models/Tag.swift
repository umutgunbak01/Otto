import SwiftUI

enum PrimaryCategory: String, Codable, CaseIterable, Identifiable {
    case work = "Work"
    case personal = "Personal"
    case hobby = "Hobby"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .work: return .blue
        case .personal: return .green
        case .hobby: return .purple
        }
    }

    var iconName: String {
        switch self {
        case .work: return "briefcase"
        case .personal: return "person"
        case .hobby: return "star"
        }
    }
}

struct DomainTag: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var isDefault: Bool
    var usageCount: Int

    init(id: UUID = UUID(), name: String, isDefault: Bool = false, usageCount: Int = 0) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.usageCount = usageCount
    }
}
