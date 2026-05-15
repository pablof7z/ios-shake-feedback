import Foundation
import ShakeFeedbackCoreFFI

enum ShakeFeedbackCoreBridge {
    private struct ErrorEnvelope: Decodable {
        let error: String?
    }

    private struct ReduceInput: Encodable {
        let events: [ShakeFeedbackEvent]
        let project_a_tag: String
        let local_pubkey: String?
    }

    private struct ThreadInput: Encodable {
        let events: [ShakeFeedbackEvent]
        let root_event_id: String
    }

    private struct RustMetadata: Decodable {
        let root_id: String
        let title: String?
        let summary: String?
        let status_label: String?
        let current_activity: String?
        let created_at: Int
    }

    private struct RustThread: Decodable {
        let root: ShakeFeedbackEvent
        let replies: [ShakeFeedbackEvent]
        let metadata: RustMetadata?
        let title: String
        let summary: String
        let status_label: String?
        let last_activity: Int
        let is_mine: Bool
    }

    private struct RustGeneratedProfile: Decodable {
        let name: String
        let display_name: String
        let about: String
        let picture: String
    }

    static func reduceThreads(
        events: [ShakeFeedbackEvent],
        projectATag: String,
        localPubkey: String?
    ) throws -> [ShakeFeedbackThread] {
        let input = ReduceInput(events: events, project_a_tag: projectATag, local_pubkey: localPubkey)
        let output = try callJSON(input) { sf_reduce_threads_json($0) }
        let rustThreads = try decode([RustThread].self, from: output)
        return rustThreads.map { thread in
            ShakeFeedbackThread(
                root: thread.root,
                replies: thread.replies,
                metadata: thread.metadata.map {
                    ShakeFeedbackMetadata(
                        rootId: $0.root_id,
                        title: $0.title,
                        summary: $0.summary,
                        statusLabel: $0.status_label,
                        currentActivity: $0.current_activity,
                        createdAt: $0.created_at
                    )
                },
                title: thread.title,
                summary: thread.summary,
                statusLabel: thread.status_label,
                lastActivity: thread.last_activity,
                isMine: thread.is_mine
            )
        }
    }

    static func threadMessages(events: [ShakeFeedbackEvent], rootEventID: String) throws -> [ShakeFeedbackEvent] {
        let input = ThreadInput(events: events, root_event_id: rootEventID)
        let output = try callJSON(input) { sf_thread_messages_json($0) }
        return try decode([ShakeFeedbackEvent].self, from: output)
    }

    static func generatedProfile(pubkey: String, appName: String) throws -> ShakeFeedbackProfile {
        let output = pubkey.withCString { pubkeyPtr in
            appName.withCString { appNamePtr in
                takeString(sf_generated_profile_json(pubkeyPtr, appNamePtr))
            }
        }
        let profile = try decode(RustGeneratedProfile.self, from: output)
        return ShakeFeedbackProfile(
            pubkey: pubkey,
            displayName: profile.display_name,
            name: profile.name,
            about: profile.about,
            picture: profile.picture
        )
    }

    private static func callJSON<T: Encodable>(_ input: T, fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) throws -> String {
        let data = try JSONEncoder.shakeFeedback.encode(input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ShakeFeedbackError.invalidEvent("Could not encode Rust input.")
        }
        return json.withCString { ptr in
            takeString(fn(ptr))
        }
    }

    private static func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return #"{"error":"null Rust response"}"# }
        defer { sf_free_string(ptr) }
        return String(cString: ptr)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        let data = Data(text.utf8)
        if let envelope = try? JSONDecoder.shakeFeedback.decode(ErrorEnvelope.self, from: data),
           let error = envelope.error {
            throw ShakeFeedbackError.rustCore(error)
        }
        return try JSONDecoder.shakeFeedback.decode(T.self, from: data)
    }
}

extension JSONEncoder {
    static let shakeFeedback: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let shakeFeedback = JSONDecoder()
}

