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

    /// Many X accounts use bare punctuation or emoji ("-", ".", ",") as
    /// their display name, which reads as broken UI when rendered as a
    /// title. True only when the name carries at least one letter or digit.
    var hasMeaningfulName: Bool {
        displayName.contains { $0.isLetter || $0.isNumber }
    }

    /// Title shown in rows and detail headers: the display name when it
    /// carries any signal, otherwise the @handle.
    var displayLabel: String {
        hasMeaningfulName ? displayName : "@\(username)"
    }

    var initials: String {
        let parts = displayName.split(separator: " ")
            .filter { part in part.contains { $0.isLetter || $0.isNumber } }
        guard let firstPart = parts.first else {
            return username.first.map { String($0).uppercased() } ?? "?"
        }
        let first = firstPart.first.map(String.init) ?? ""
        let last = parts.count > 1 ? (parts.last!.first.map(String.init) ?? "") : ""
        return "\(first)\(last)".uppercased()
    }

    /// X serves `profile_image_url` at the tiny `_normal` (48px) variant;
    /// swapping the suffix fetches the 400px original for detail headers.
    var profileImageLargeUrl: String? {
        profileImageUrl?.replacingOccurrences(of: "_normal.", with: "_400x400.")
    }

    var profileURL: URL? {
        URL(string: "https://x.com/\(username)")
    }

    var searchableContent: String {
        [username, displayName, bio].joined(separator: " ")
    }
}
