import Foundation

struct Bookmark: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var description: String
    var mediaType: MediaType
    var primaryCategory: PrimaryCategory
    var domainTagIds: [UUID]
    var isRead: Bool
    var ogImageUrl: String?
    var ogDescription: String?
    var faviconUrl: String?
    var siteName: String?
    var createdAt: Date
    var updatedAt: Date

    enum MediaType: String, Codable, CaseIterable, Identifiable {
        case readLater = "Read Later"
        case listenLater = "Listen Later"
        case watchLater = "Watch Later"

        var id: String { rawValue }

        var iconName: String {
            switch self {
            case .readLater: return "book"
            case .listenLater: return "headphones"
            case .watchLater: return "play.rectangle"
            }
        }
    }

    init(
        id: UUID = UUID(),
        title: String,
        url: String,
        description: String = "",
        mediaType: MediaType = .readLater,
        primaryCategory: PrimaryCategory = .personal,
        domainTagIds: [UUID] = [],
        isRead: Bool = false,
        ogImageUrl: String? = nil,
        ogDescription: String? = nil,
        faviconUrl: String? = nil,
        siteName: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.description = description
        self.mediaType = mediaType
        self.primaryCategory = primaryCategory
        self.domainTagIds = domainTagIds
        self.isRead = isRead
        self.ogImageUrl = ogImageUrl
        self.ogDescription = ogDescription
        self.faviconUrl = faviconUrl
        self.siteName = siteName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
