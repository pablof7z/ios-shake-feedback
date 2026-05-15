import Foundation

public struct ShakeFeedbackConfig: Sendable, Equatable {
    public var appName: String
    public var clientTag: String
    public var projectATag: String
    public var agentPubkey: String?
    public var feedbackRelayURL: URL
    public var profileRelayURLs: [URL]
    public var showEveryoneByDefault: Bool

    public init(
        appName: String,
        clientTag: String,
        projectATag: String,
        agentPubkey: String? = nil,
        feedbackRelayURL: URL = URL(string: "wss://relay.tenex.chat")!,
        profileRelayURLs: [URL] = [
            URL(string: "wss://relay.tenex.chat")!,
            URL(string: "wss://purplepag.es")!,
        ],
        showEveryoneByDefault: Bool = false
    ) {
        self.appName = appName
        self.clientTag = clientTag
        self.projectATag = projectATag
        self.agentPubkey = agentPubkey
        self.feedbackRelayURL = feedbackRelayURL
        self.profileRelayURLs = profileRelayURLs
        self.showEveryoneByDefault = showEveryoneByDefault
    }
}

public struct ShakeFeedbackEventDraft: Sendable, Equatable {
    public var kind: Int
    public var content: String
    public var tags: [[String]]
    public var createdAt: Int

    public init(kind: Int, content: String, tags: [[String]], createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.kind = kind
        self.content = content
        self.tags = tags
        self.createdAt = createdAt
    }
}

public struct ShakeFeedbackEvent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pubkey: String
    public var created_at: Int
    public var kind: Int
    public var tags: [[String]]
    public var content: String
    public var sig: String

    public init(id: String, pubkey: String, createdAt: Int, kind: Int, tags: [[String]], content: String, sig: String) {
        self.id = id
        self.pubkey = pubkey
        self.created_at = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }
}

public struct ShakeFeedbackMetadata: Codable, Equatable, Hashable, Sendable {
    public var rootId: String
    public var title: String?
    public var summary: String?
    public var statusLabel: String?
    public var currentActivity: String?
    public var createdAt: Int
}

public struct ShakeFeedbackThread: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var root: ShakeFeedbackEvent
    public var replies: [ShakeFeedbackEvent]
    public var metadata: ShakeFeedbackMetadata?
    public var title: String
    public var summary: String
    public var statusLabel: String?
    public var lastActivity: Int
    public var isMine: Bool

    public var id: String { root.id }
    public var messages: [ShakeFeedbackEvent] {
        ([root] + replies).sorted {
            if $0.created_at == $1.created_at { return $0.id < $1.id }
            return $0.created_at < $1.created_at
        }
    }
}

public struct ShakeFeedbackProfile: Codable, Equatable, Hashable, Sendable {
    public var pubkey: String
    public var displayName: String
    public var name: String?
    public var about: String?
    public var picture: String?

    public var pictureURL: URL? {
        guard let picture, !picture.isEmpty else { return nil }
        return URL(string: picture)
    }

    public var initials: String {
        let chars = displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
        let value = String(chars).uppercased()
        return value.isEmpty ? "?" : value
    }
}

public enum ShakeFeedbackIdentityMode: String, Codable, Sendable, Equatable {
    case generated
    case importedNsec
    case remoteSigner
    case hostApp
    case missing
}

public enum ShakeFeedbackError: LocalizedError, Sendable {
    case missingIdentity
    case emptyMessage
    case invalidEvent(String)
    case invalidRelayMessage
    case relayRejected(String)
    case relayTimeout
    case invalidIdentity(String)
    case rustCore(String)

    public var errorDescription: String? {
        switch self {
        case .missingIdentity:
            return "No feedback identity is available."
        case .emptyMessage:
            return "Feedback cannot be empty."
        case .invalidEvent(let message):
            return "Invalid feedback event: \(message)"
        case .invalidRelayMessage:
            return "Relay returned an invalid message."
        case .relayRejected(let message):
            return message
        case .relayTimeout:
            return "The feedback relay timed out."
        case .invalidIdentity(let message):
            return message
        case .rustCore(let message):
            return message
        }
    }
}

extension ShakeFeedbackEvent {
    var rootEventID: String? {
        tags.first { $0.first == "e" && $0.count >= 4 && $0[3] == "root" }?[1]
    }

    var anyRootEventID: String? {
        rootEventID ?? tags.first { $0.first == "e" && $0.count >= 2 }?[1]
    }
}

