import Foundation

public enum ShakeFeedbackRelayFrame: Sendable, Equatable {
    case connected
    case disconnected(String?)
    case event(subscriptionID: String, event: ShakeFeedbackEvent)
    case eose(subscriptionID: String)
    case ok(eventID: String, accepted: Bool, message: String?)
    case auth(challenge: String)
    case notice(String)
    case closed(subscriptionID: String, message: String?)
}

public struct ShakeFeedbackFilter: Encodable, Sendable, Equatable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [Int]?
    public var since: Int?
    public var until: Int?
    public var limit: Int?
    public var eTags: [String]?
    public var aTags: [String]?
    public var pTags: [String]?

    enum CodingKeys: String, CodingKey {
        case ids
        case authors
        case kinds
        case since
        case until
        case limit
        case eTags = "#e"
        case aTags = "#a"
        case pTags = "#p"
    }

    public init(
        ids: [String]? = nil,
        authors: [String]? = nil,
        kinds: [Int]? = nil,
        since: Int? = nil,
        until: Int? = nil,
        limit: Int? = nil,
        eTags: [String]? = nil,
        aTags: [String]? = nil,
        pTags: [String]? = nil
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.since = since
        self.until = until
        self.limit = limit
        self.eTags = eTags
        self.aTags = aTags
        self.pTags = pTags
    }
}

public actor ShakeFeedbackRelay {
    private let url: URL
    private var task: URLSessionWebSocketTask?
    private var continuations: [UUID: AsyncStream<ShakeFeedbackRelayFrame>.Continuation] = [:]
    private var receiveTask: Task<Void, Never>?
    private var subscriptions: [String: ShakeFeedbackFilter] = [:]
    private var authSigner: (any ShakeFeedbackSigner)?
    private var lastAuthChallenge: String?

    public init(url: URL) {
        self.url = url
    }

    public func setAuthSigner(_ signer: (any ShakeFeedbackSigner)?) {
        self.authSigner = signer
    }

    public func frames() -> AsyncStream<ShakeFeedbackRelayFrame> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { self.addContinuation(id, continuation) }
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
            Task { self.connectIfNeeded() }
        }
    }

    public func fetch(filter: ShakeFeedbackFilter, timeoutSeconds: TimeInterval = 8) async throws -> [ShakeFeedbackEvent] {
        let subscriptionID = "sf-\(UUID().uuidString)"
        connectIfNeeded()
        try await sendREQ(subscriptionID: subscriptionID, filter: filter)

        var events: [ShakeFeedbackEvent] = []
        var authenticated = false
        for try await frame in frames(timeoutSeconds: timeoutSeconds) {
            switch frame {
            case .event(let subID, let event) where subID == subscriptionID:
                events.append(event)
            case .eose(let subID) where subID == subscriptionID:
                try? await close(subscriptionID: subscriptionID)
                return events
            case .closed(let subID, let message) where subID == subscriptionID:
                if message?.hasPrefix("auth-required:") == true, !authenticated, let authSigner {
                    if try await authenticateWithLastChallengeIfNeeded(authSigner: authSigner) {
                        authenticated = true
                        try await sendREQ(subscriptionID: subscriptionID, filter: filter)
                    } else {
                        throw ShakeFeedbackError.relayRejected("Relay requires authentication but did not provide a challenge.")
                    }
                } else {
                    return events
                }
            case .auth(let challenge):
                if let authSigner {
                    try await sendAuth(challenge: challenge, signer: authSigner)
                    authenticated = true
                }
            case .notice(let message):
                throw ShakeFeedbackError.relayRejected(message)
            default:
                break
            }
        }
        return events
    }

    public func subscribe(id: String, filter: ShakeFeedbackFilter) async throws {
        connectIfNeeded()
        subscriptions[id] = filter
        try await sendREQ(subscriptionID: id, filter: filter)
    }

    public func close(subscriptionID: String) async throws {
        subscriptions.removeValue(forKey: subscriptionID)
        try await send(["CLOSE", subscriptionID])
    }

    public func publishAndAwaitOK(
        _ event: ShakeFeedbackEvent,
        signer: (any ShakeFeedbackSigner)?,
        timeoutSeconds: TimeInterval = 8
    ) async throws {
        connectIfNeeded()
        try await send(["EVENT", event.dictionary])
        var authed = false
        for try await frame in frames(timeoutSeconds: timeoutSeconds) {
            switch frame {
            case .ok(let eventID, let accepted, let message) where eventID == event.id:
                if accepted { return }
                if message?.hasPrefix("auth-required:") == true, !authed, let signer {
                    if try await authenticateWithLastChallengeIfNeeded(authSigner: signer) {
                        authed = true
                        try await send(["EVENT", event.dictionary])
                    }
                    continue
                }
                throw ShakeFeedbackError.relayRejected(message ?? "Relay rejected feedback.")
            case .auth(let challenge):
                guard let signer else { throw ShakeFeedbackError.relayRejected("Relay requires authentication.") }
                try await sendAuth(challenge: challenge, signer: signer)
                authed = true
                try await send(["EVENT", event.dictionary])
            case .notice(let message):
                throw ShakeFeedbackError.relayRejected(message)
            default:
                break
            }
        }
        throw ShakeFeedbackError.relayTimeout
    }

    public func stop() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        yield(.disconnected(nil))
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    private func connectIfNeeded() {
        guard task == nil else { return }
        let newTask = URLSession.shared.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        yield(.connected)
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(task: newTask)
        }
    }

    private func receiveLoop(task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    if let frame = Self.parse(text) {
                        if case .auth(let challenge) = frame {
                            lastAuthChallenge = challenge
                        }
                        yield(frame)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8),
                       let frame = Self.parse(text) {
                        if case .auth(let challenge) = frame {
                            lastAuthChallenge = challenge
                        }
                        yield(frame)
                    }
                @unknown default:
                    break
                }
            } catch {
                yield(.disconnected(error.localizedDescription))
                self.task = nil
                return
            }
        }
    }

    private func yield(_ frame: ShakeFeedbackRelayFrame) {
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }

    private func addContinuation(_ id: UUID, _ continuation: AsyncStream<ShakeFeedbackRelayFrame>.Continuation) {
        continuations[id] = continuation
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func frames(timeoutSeconds: TimeInterval) -> AsyncThrowingStream<ShakeFeedbackRelayFrame, Error> {
        let stream = frames()
        return AsyncThrowingStream { continuation in
            let pumpTask = Task {
                for await frame in stream {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            let timeoutTask = Task {
                let nanoseconds = UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                continuation.finish(throwing: ShakeFeedbackError.relayTimeout)
            }
            continuation.onTermination = { _ in
                pumpTask.cancel()
                timeoutTask.cancel()
            }
        }
    }

    private func authenticateWithLastChallengeIfNeeded(authSigner: any ShakeFeedbackSigner) async throws -> Bool {
        guard let lastAuthChallenge else { return false }
        try await sendAuth(challenge: lastAuthChallenge, signer: authSigner)
        return true
    }

    private func sendAuth(challenge: String, signer: any ShakeFeedbackSigner) async throws {
        let draft = ShakeFeedbackEventDraft(
            kind: 22242,
            content: "",
            tags: [["relay", url.absoluteString], ["challenge", challenge]]
        )
        let event = try await signer.signFeedbackEvent(draft)
        try await send(["AUTH", event.dictionary])
    }

    private func sendREQ(subscriptionID: String, filter: ShakeFeedbackFilter) async throws {
        let filterData = try JSONEncoder.shakeFeedback.encode(filter)
        let filterObject = try JSONSerialization.jsonObject(with: filterData)
        try await send(["REQ", subscriptionID, filterObject])
    }

    private func send(_ value: [Any]) async throws {
        guard let task else { throw ShakeFeedbackError.relayRejected("Relay is not connected.") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ShakeFeedbackError.invalidRelayMessage
        }
        try await task.send(.string(text))
    }

    private static func parse(_ text: String) -> ShakeFeedbackRelayFrame? {
        guard let data = text.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let type = array.first as? String
        else { return nil }
        switch type {
        case "EVENT":
            guard array.count >= 3,
                  let subID = array[1] as? String,
                  let eventData = try? JSONSerialization.data(withJSONObject: array[2]),
                  let event = try? JSONDecoder.shakeFeedback.decode(ShakeFeedbackEvent.self, from: eventData)
            else { return nil }
            return .event(subscriptionID: subID, event: event)
        case "EOSE":
            guard let subID = array[safe: 1] as? String else { return nil }
            return .eose(subscriptionID: subID)
        case "OK":
            guard let eventID = array[safe: 1] as? String,
                  let accepted = array[safe: 2] as? Bool
            else { return nil }
            return .ok(eventID: eventID, accepted: accepted, message: array[safe: 3] as? String)
        case "AUTH":
            guard let challenge = array[safe: 1] as? String else { return nil }
            return .auth(challenge: challenge)
        case "NOTICE":
            return .notice((array[safe: 1] as? String) ?? "Relay notice.")
        case "CLOSED":
            guard let subID = array[safe: 1] as? String else { return nil }
            return .closed(subscriptionID: subID, message: array[safe: 2] as? String)
        default:
            return nil
        }
    }
}

extension ShakeFeedbackEvent {
    var dictionary: [String: Any] {
        [
            "id": id,
            "pubkey": pubkey,
            "created_at": created_at,
            "kind": kind,
            "tags": tags,
            "content": content,
            "sig": sig,
        ]
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
