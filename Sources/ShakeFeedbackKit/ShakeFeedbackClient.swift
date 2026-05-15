import Foundation
import Observation

public actor ShakeFeedbackClient {
    private let config: ShakeFeedbackConfig
    private let feedbackRelay: ShakeFeedbackRelay
    private let profileRelays: [ShakeFeedbackRelay]
    private let identityStore: ShakeFeedbackIdentityStore
    private var projectEventSubscriptionTask: Task<Void, Never>?

    public init(config: ShakeFeedbackConfig, identityStore: ShakeFeedbackIdentityStore) {
        self.config = config
        self.identityStore = identityStore
        self.feedbackRelay = ShakeFeedbackRelay(url: config.feedbackRelayURL)
        self.profileRelays = config.profileRelayURLs.map { ShakeFeedbackRelay(url: $0) }
    }

    public func configure(hostSigner: (any ShakeFeedbackSigner)? = nil) async {
        await identityStore.start(hostSigner: hostSigner)
        let signer = await identityStore.activeSigner
        await feedbackRelay.setAuthSigner(signer)
        for relay in profileRelays {
            await relay.setAuthSigner(signer)
        }
    }

    public func loadProjectEvents() async throws -> [ShakeFeedbackEvent] {
        try await feedbackRelay.fetch(
            filter: ShakeFeedbackFilter(kinds: [1, 513], limit: 300, aTags: [config.projectATag]),
            timeoutSeconds: 8
        )
    }

    public func reduceProjectEvents(_ events: [ShakeFeedbackEvent], mineOnly: Bool = false) async throws -> [ShakeFeedbackThread] {
        let signer = await identityStore.activeSigner
        let pubkey = await signer?.publicKeyHex
        let reduced = try ShakeFeedbackCoreBridge.reduceThreads(
            events: events,
            projectATag: config.projectATag,
            localPubkey: pubkey
        )
        return mineOnly ? reduced.filter(\.isMine) : reduced
    }

    public func loadThreads(mineOnly: Bool = false) async throws -> [ShakeFeedbackThread] {
        let events = try await loadProjectEvents()
        return try await reduceProjectEvents(events, mineOnly: mineOnly)
    }

    public nonisolated func reduceConversationEvents(_ events: [ShakeFeedbackEvent], rootEventID: String) throws -> [ShakeFeedbackEvent] {
        try ShakeFeedbackCoreBridge.threadMessages(events: events, rootEventID: rootEventID)
    }

    public func loadConversation(rootEventID: String) async throws -> [ShakeFeedbackEvent] {
        async let root = feedbackRelay.fetch(filter: ShakeFeedbackFilter(ids: [rootEventID], limit: 1), timeoutSeconds: 6)
        async let replies = feedbackRelay.fetch(filter: ShakeFeedbackFilter(kinds: [1, 513], limit: 300, eTags: [rootEventID]), timeoutSeconds: 6)
        let events = try await root + replies
        return try ShakeFeedbackCoreBridge.threadMessages(events: events, rootEventID: rootEventID)
    }

    @discardableResult
    public func sendThread(content: String) async throws -> ShakeFeedbackThread {
        let event = try await signAndPublish(content: content, rootEventID: nil, replyToPubkey: config.agentPubkey)
        return ShakeFeedbackThread(
            root: event,
            replies: [],
            metadata: nil,
            title: preview(event.content, fallback: "Feedback"),
            summary: preview(event.content, fallback: "No messages yet"),
            statusLabel: nil,
            lastActivity: event.created_at,
            isMine: true
        )
    }

    @discardableResult
    public func sendReply(content: String, in thread: ShakeFeedbackThread) async throws -> ShakeFeedbackEvent {
        let signer = await identityStore.activeSigner
        let myPubkey = await signer?.publicKeyHex
        let lastOther = thread.messages.last(where: { $0.pubkey != myPubkey })?.pubkey
        return try await signAndPublish(content: content, rootEventID: thread.root.id, replyToPubkey: lastOther ?? config.agentPubkey)
    }

    public func loadProfiles(pubkeys: Set<String>) async throws -> [String: ShakeFeedbackProfile] {
        let missing = pubkeys.filter { !$0.isEmpty }
        guard !missing.isEmpty else { return [:] }
        var latest: [String: (event: ShakeFeedbackEvent, profile: ShakeFeedbackProfile)] = [:]
        for relay in profileRelays {
            let events = try await relay.fetch(
                filter: ShakeFeedbackFilter(authors: Array(missing), kinds: [0], limit: max(missing.count * 2, 10)),
                timeoutSeconds: 5
            )
            for event in events where event.kind == 0 {
                guard let profile = Self.profile(from: event) else { continue }
                if let current = latest[event.pubkey], current.event.created_at > event.created_at {
                    continue
                }
                latest[event.pubkey] = (event, profile)
            }
        }
        var output = latest.mapValues(\.profile)
        for pubkey in missing where output[pubkey] == nil {
            output[pubkey] = ShakeFeedbackProfile(pubkey: pubkey, displayName: Self.shortNpub(pubkey), name: nil, about: nil, picture: nil)
        }
        return output
    }

    public func subscribeProjectEvents(since: Int? = nil, _ onEvent: @escaping @Sendable (ShakeFeedbackEvent) async -> Void) async throws {
        try await feedbackRelay.subscribe(
            id: "shake-feedback-\(config.clientTag)",
            filter: ShakeFeedbackFilter(kinds: [1, 513], since: since, aTags: [config.projectATag])
        )
        let stream = await feedbackRelay.frames()
        projectEventSubscriptionTask?.cancel()
        projectEventSubscriptionTask = Task {
            for await frame in stream {
                if case .event(_, let event) = frame {
                    await onEvent(event)
                }
            }
        }
    }

    public func stopSubscriptions() {
        projectEventSubscriptionTask?.cancel()
        projectEventSubscriptionTask = nil
    }

    private func signAndPublish(content: String, rootEventID: String?, replyToPubkey: String?) async throws -> ShakeFeedbackEvent {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ShakeFeedbackError.emptyMessage }
        guard let signer = await identityStore.activeSigner else { throw ShakeFeedbackError.missingIdentity }

        if await identityStore.needsGeneratedProfilePublish {
            try await publishGeneratedProfileIfNeeded(signer: signer)
        }

        var tags = [["a", config.projectATag], ["client", config.clientTag]]
        if let rootEventID {
            tags.append(["e", rootEventID, "", "root"])
        }
        if let replyToPubkey, !replyToPubkey.isEmpty {
            tags.append(["p", replyToPubkey])
        }
        let event = try await signer.signFeedbackEvent(ShakeFeedbackEventDraft(kind: 1, content: trimmed, tags: tags))
        try await feedbackRelay.publishAndAwaitOK(event, signer: signer, timeoutSeconds: 8)
        return event
    }

    private func publishGeneratedProfileIfNeeded(signer: any ShakeFeedbackSigner) async throws {
        guard let pubkey = await signer.publicKeyHex else { return }
        let profile = try ShakeFeedbackCoreBridge.generatedProfile(pubkey: pubkey, appName: config.appName)
        let contentObject: [String: String] = [
            "name": profile.name ?? "",
            "display_name": profile.displayName,
            "about": profile.about ?? "",
            "picture": profile.picture ?? "",
        ]
        let contentData = try JSONSerialization.data(withJSONObject: contentObject, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let content = String(data: contentData, encoding: .utf8) else { return }
        let event = try await signer.signFeedbackEvent(ShakeFeedbackEventDraft(kind: 0, content: content, tags: []))
        for relay in profileRelays {
            try? await relay.publishAndAwaitOK(event, signer: signer, timeoutSeconds: 5)
        }
        await identityStore.markGeneratedProfilePublished()
    }

    private static func profile(from event: ShakeFeedbackEvent) -> ShakeFeedbackProfile? {
        guard let data = event.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let display = object["display_name"] as? String
            ?? object["displayName"] as? String
            ?? object["name"] as? String
            ?? shortNpub(event.pubkey)
        return ShakeFeedbackProfile(
            pubkey: event.pubkey,
            displayName: display,
            name: object["name"] as? String,
            about: object["about"] as? String,
            picture: object["picture"] as? String
        )
    }

    private static func shortNpub(_ pubkey: String) -> String {
        guard pubkey.count > 12 else { return pubkey }
        return "\(pubkey.prefix(6))...\(pubkey.suffix(4))"
    }

    private func preview(_ text: String, fallback: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return fallback }
        return String(collapsed.prefix(90))
    }
}

@MainActor
@Observable
public final class ShakeFeedbackStore {
    public private(set) var threads: [ShakeFeedbackThread] = []
    public private(set) var currentMessages: [String: [ShakeFeedbackEvent]] = [:]
    public private(set) var profiles: [String: ShakeFeedbackProfile] = [:]
    public private(set) var isLoading = false
    public private(set) var lastError: String?
    public var mineOnly: Bool

    public let identity: ShakeFeedbackIdentityStore
    private let client: ShakeFeedbackClient
    private var projectEventsByID: [String: ShakeFeedbackEvent] = [:]

    public init(config: ShakeFeedbackConfig, namespace: String? = nil) {
        self.mineOnly = !config.showEveryoneByDefault
        self.identity = ShakeFeedbackIdentityStore(namespace: namespace ?? config.clientTag)
        self.client = ShakeFeedbackClient(config: config, identityStore: identity)
    }

    public func start(hostSigner: (any ShakeFeedbackSigner)? = nil) async {
        await client.configure(hostSigner: hostSigner)
        await reloadProjectEvents(showInitialLoading: threads.isEmpty)
        do {
            try await client.subscribeProjectEvents(since: Int(Date().timeIntervalSince1970) - 5) { [weak self] event in
                await self?.handleProjectEvent(event)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func refresh() async {
        await reloadProjectEvents(showInitialLoading: threads.isEmpty)
    }

    private func reloadProjectEvents(showInitialLoading: Bool) async {
        if showInitialLoading {
            isLoading = true
        }
        defer { isLoading = false }
        do {
            let events = try await client.loadProjectEvents()
            projectEventsByID.removeAll(keepingCapacity: true)
            for event in events {
                projectEventsByID[event.id] = event
            }
            try await rebuildVisibleThreads()
            await loadProfilesForVisibleThreads()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func loadConversation(_ thread: ShakeFeedbackThread) async {
        do {
            if let cached = currentMessages[thread.root.id], !cached.isEmpty {
                let loaded = try await client.loadProfiles(pubkeys: missingProfilePubkeys(in: cached))
                profiles.merge(loaded) { _, new in new }
                return
            }

            let messages = try await client.loadConversation(rootEventID: thread.root.id)
            currentMessages[thread.root.id] = messages
            for event in messages {
                projectEventsByID[event.id] = event
            }
            try await rebuildVisibleThreads()
            let pubkeys = Set(messages.map(\.pubkey))
            let loaded = try await client.loadProfiles(pubkeys: Set(pubkeys.filter { profiles[$0] == nil }))
            profiles.merge(loaded) { _, new in new }
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    public func sendThread(content: String) async throws -> ShakeFeedbackThread {
        let thread = try await client.sendThread(content: content)
        for event in thread.messages {
            projectEventsByID[event.id] = event
        }
        try await rebuildVisibleThreads()
        return thread
    }

    @discardableResult
    public func sendReply(content: String, in thread: ShakeFeedbackThread) async throws -> ShakeFeedbackEvent {
        let event = try await client.sendReply(content: content, in: thread)
        projectEventsByID[event.id] = event
        currentMessages[thread.root.id, default: thread.messages].append(event)
        currentMessages[thread.root.id]?.sort {
            if $0.created_at == $1.created_at { return $0.id < $1.id }
            return $0.created_at < $1.created_at
        }
        try await rebuildVisibleThreads()
        return event
    }

    public func setMineOnly(_ mineOnly: Bool) async {
        guard self.mineOnly != mineOnly else { return }
        self.mineOnly = mineOnly
        do {
            try await rebuildVisibleThreads()
            await loadProfilesForVisibleThreads()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func profile(for pubkey: String) -> ShakeFeedbackProfile {
        profiles[pubkey] ?? ShakeFeedbackProfile(pubkey: pubkey, displayName: String(pubkey.prefix(8)), name: nil, about: nil, picture: nil)
    }

    private func loadProfilesForVisibleThreads() async {
        do {
            let pubkeys = Set(threads.flatMap { $0.messages.map(\.pubkey) })
            let loaded = try await client.loadProfiles(pubkeys: Set(pubkeys.filter { profiles[$0] == nil }))
            profiles.merge(loaded) { _, new in new }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleProjectEvent(_ event: ShakeFeedbackEvent) async {
        let existing = projectEventsByID[event.id]
        projectEventsByID[event.id] = event

        do {
            try await rebuildVisibleThreads()
            updateLoadedConversation(with: event)
            if existing == nil {
                await loadProfilesForVisibleThreads()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rebuildVisibleThreads() async throws {
        threads = try await client.reduceProjectEvents(Array(projectEventsByID.values), mineOnly: mineOnly)
    }

    private func updateLoadedConversation(with event: ShakeFeedbackEvent) {
        let rootID: String?
        if currentMessages[event.id] != nil {
            rootID = event.id
        } else {
            rootID = event.anyRootEventID
        }
        guard let rootID, currentMessages[rootID] != nil else { return }
        let events = Array(projectEventsByID.values)
        currentMessages[rootID] = (try? client.reduceConversationEvents(events, rootEventID: rootID)) ?? currentMessages[rootID]
    }

    private func missingProfilePubkeys(in events: [ShakeFeedbackEvent]) -> Set<String> {
        Set(Set(events.map(\.pubkey)).filter { profiles[$0] == nil })
    }
}
