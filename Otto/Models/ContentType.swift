import SwiftUI

enum ContentType: String, Codable, CaseIterable, Identifiable {
    case todo = "todo"
    case note = "note"
    case idea = "idea"
    case reminder = "reminder"
    case bookmark = "bookmark"
    case meeting = "meeting"
    case email = "email"
    case connection = "connection"
    case networkHub = "networkHub"
    case company = "company"
    case event = "event"
    case community = "community"
    case file = "file"
    case xPost = "xPost"
    case xFollower = "xFollower"
    case xDm = "xDm"
    case habit = "habit"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .todo: return "To-Do"
        case .note: return "Note"
        case .idea: return "Idea"
        case .reminder: return "Reminder"
        case .bookmark: return "Bookmark"
        case .meeting: return "Meeting"
        case .email: return "Email"
        case .connection: return "LinkedIn Connections"
        case .networkHub: return "Network Hub"
        case .company: return "Companies"
        case .event: return "Events"
        case .community: return "Communities"
        case .file: return "Files"
        case .xPost: return "X Posts"
        case .xFollower: return "X Followers"
        case .xDm: return "X DMs"
        case .habit: return "Habits"
        }
    }

    var iconName: String {
        switch self {
        case .todo: return "checkmark.circle"
        case .note: return "note.text"
        case .idea: return "lightbulb"
        case .reminder: return "bell"
        case .bookmark: return "bookmark"
        case .meeting: return "video"
        case .email: return "envelope"
        case .connection: return "person.2"
        case .networkHub: return "point.3.connected.trianglepath.dotted"
        case .company: return "building.2"
        case .event: return "calendar"
        case .community: return "person.3"
        case .file: return "doc.fill"
        case .xPost: return "text.bubble.fill"
        case .xFollower: return "person.2.fill"
        case .xDm: return "message.fill"
        case .habit: return "flame"
        }
    }

    var color: Color {
        switch self {
        case .todo:       return Theme.Colors.cyan
        case .note:       return Theme.Colors.cyanDim
        case .idea:       return Theme.Colors.amber
        case .reminder:   return Theme.Colors.amber
        case .bookmark:   return Theme.Colors.red
        case .meeting:    return Theme.Colors.cyan
        case .email:      return Theme.Colors.aiAccent
        case .connection: return Theme.Colors.green
        case .networkHub: return Theme.Colors.hobby
        case .company:    return Theme.Colors.green
        case .event:      return Theme.Colors.amber
        case .community:  return Theme.Colors.aiAccent
        case .file:       return Theme.Colors.textDim
        case .xPost:      return Theme.Colors.aiAccent
        case .xFollower:  return Theme.Colors.green
        case .xDm:        return Theme.Colors.cyan
        case .habit:      return Theme.Colors.green
        }
    }
}
