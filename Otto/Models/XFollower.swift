import Foundation

struct XFollower: Identifiable, Codable, Hashable {
    let id: UUID
    var xUserId: String
    var username: String
    var displayName: String
    var bio: String
    var profileImageUrl: String?
    var followersCount: Int
    var followingCount: Int
    var isMutual: Bool
    var linkedConnectionId: UUID?
    var syncUpdatedAt: Date

    init(
        id: UUID = UUID(),
        xUserId: String,
        username: String = "",
        displayName: String = "",
        bio: String = "",
        profileImageUrl: String? = nil,
        followersCount: Int = 0,
        followingCount: Int = 0,
        isMutual: Bool = false,
        linkedConnectionId: UUID? = nil,
        syncUpdatedAt: Date = Date()
    ) {
        self.id = id
        self.xUserId = xUserId
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.profileImageUrl = profileImageUrl
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.isMutual = isMutual
        self.linkedConnectionId = linkedConnectionId
        self.syncUpdatedAt = syncUpdatedAt
    }

    // MARK: - Computed

    var initials: String {
        let parts = displayName.split(separator: " ")
        let first = parts.first.map { String($0.first ?? Character("")) } ?? ""
        let last = parts.count > 1 ? String(parts.last!.first ?? Character("")) : ""
        return "\(first)\(last)".uppercased()
    }

    var searchableContent: String {
        [username, displayName, bio].joined(separator: " ")
    }
}
