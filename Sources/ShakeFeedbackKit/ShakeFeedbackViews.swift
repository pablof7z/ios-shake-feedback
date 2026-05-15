import SwiftUI

public struct ShakeFeedbackSheet: View {
    @Bindable private var store: ShakeFeedbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var composePresented = false
    @State private var identityPresented = false

    public init(store: ShakeFeedbackStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Feedback")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .principal) {
                        if !store.identity.usesHostIdentity {
                            Button { identityPresented = true } label: {
                                Image(systemName: store.identity.publicKeyHex == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                            }
                            .accessibilityLabel("Feedback account")
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button { composePresented = true } label: {
                            Label("New feedback", systemImage: "square.and.pencil")
                        }
                    }
                }
                .refreshable { await store.refresh() }
                .sheet(isPresented: $composePresented) {
                    ShakeFeedbackComposeSheet(store: store)
                }
                .sheet(isPresented: $identityPresented) {
                    ShakeFeedbackIdentitySheet(store: store)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.threads.isEmpty {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.lastError, store.threads.isEmpty {
            ContentUnavailableView("Feedback unavailable", systemImage: "wifi.exclamationmark", description: Text(error))
        } else {
            List {
                Section {
                    Picker("Show", selection: Binding(
                        get: { store.mineOnly },
                        set: { value in Task { await store.setMineOnly(value) } }
                    )) {
                        Text("Mine").tag(true)
                        Text("Everyone").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)
                }

                if store.threads.isEmpty {
                    ContentUnavailableView(
                        store.mineOnly ? "No feedback from you" : "No project feedback",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a thread and it will stay attached to this project.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(store.threads) { thread in
                        NavigationLink {
                            ShakeFeedbackConversationView(store: store, thread: thread)
                        } label: {
                            ShakeFeedbackThreadRow(thread: thread, author: authorName(for: thread))
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func authorName(for thread: ShakeFeedbackThread) -> String? {
        guard !store.mineOnly else { return nil }
        if thread.isMine { return "You" }
        return store.profile(for: thread.root.pubkey).displayName
    }
}

public struct ShakeFeedbackConversationView: View {
    @Bindable private var store: ShakeFeedbackStore
    let thread: ShakeFeedbackThread
    @State private var draft = ""
    @State private var isSending = false

    public init(store: ShakeFeedbackStore, thread: ShakeFeedbackThread) {
        self.store = store
        self.thread = thread
    }

    private var messages: [ShakeFeedbackEvent] {
        store.currentMessages[thread.root.id] ?? thread.messages
    }

    public var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if let summary = thread.metadata?.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            ShakeFeedbackBubble(
                                event: message,
                                profile: store.profile(for: message.pubkey),
                                isMine: message.pubkey == store.identity.publicKeyHex,
                                showsHeader: index == 0 || messages[index - 1].pubkey != message.pubkey
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                Divider()
                composer
            }
            .navigationTitle(thread.title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await store.loadConversation(thread)
                if let last = messages.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button {
                send()
            } label: {
                Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    private func send() {
        let value = draft
        draft = ""
        isSending = true
        Task {
            defer { isSending = false }
            _ = try? await store.sendReply(content: value, in: thread)
        }
    }
}

public struct ShakeFeedbackThreadRow: View {
    let thread: ShakeFeedbackThread
    let author: String?

    public init(thread: ShakeFeedbackThread, author: String? = nil) {
        self.thread = thread
        self.author = author
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(thread.title)
                    .font(.body.weight(thread.metadata?.title == nil ? .regular : .semibold))
                    .lineLimit(1)
                Spacer()
                Text(Date(timeIntervalSince1970: TimeInterval(thread.lastActivity)), style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(thread.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let status = thread.statusLabel, !status.isEmpty {
                    Text(status)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.14), in: Capsule())
                }
                if !thread.replies.isEmpty {
                    Text("\(thread.replies.count) replies")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

public struct ShakeFeedbackBubble: View {
    let event: ShakeFeedbackEvent
    let profile: ShakeFeedbackProfile
    let isMine: Bool
    let showsHeader: Bool

    public init(event: ShakeFeedbackEvent, profile: ShakeFeedbackProfile, isMine: Bool, showsHeader: Bool) {
        self.event = event
        self.profile = profile
        self.isMine = isMine
        self.showsHeader = showsHeader
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMine { Spacer(minLength: 36) }
            if !isMine {
                avatar.opacity(showsHeader ? 1 : 0)
            }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if showsHeader {
                    Text(isMine ? "You" : profile.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if !textOnlyContent.isEmpty {
                    Text(markdownContent)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(isMine ? .white : .primary)
                        .background(isMine ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                ForEach(imageURLs, id: \.absoluteString) { url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            Label("Image unavailable", systemImage: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(8)
                        default:
                            Color.secondary.opacity(0.15)
                                .frame(height: 120)
                        }
                    }
                    .frame(maxWidth: 280)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }
            if !isMine { Spacer(minLength: 36) }
        }
        .padding(.horizontal)
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp"]

    private var imageURLs: [URL] {
        event.content.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: text),
                  url.scheme == "https" || url.scheme == "http",
                  Self.imageExtensions.contains(url.pathExtension.lowercased())
            else { return nil }
            return url
        }
    }

    private var textOnlyContent: String {
        let imageLines = Set(imageURLs.map(\.absoluteString))
        return event.content
            .components(separatedBy: "\n")
            .filter { !imageLines.contains($0.trimmingCharacters(in: .whitespaces)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var markdownContent: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var combined = AttributedString("")
        let lines = textOnlyContent.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let text = String(line)
            combined.append((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            if index < lines.count - 1 {
                combined.append(AttributedString("\n"))
            }
        }
        return combined
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.18))
            Text(profile.initials)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 28, height: 28)
    }
}

public struct ShakeFeedbackComposeSheet: View {
    @Bindable private var store: ShakeFeedbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var isSending = false
    @State private var error: String?

    public init(store: ShakeFeedbackStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $draft)
                    .frame(minHeight: 180)
                    .padding(8)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("New Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSending ? "Sending..." : "Send") {
                        send()
                    }
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func send() {
        isSending = true
        error = nil
        Task {
            do {
                _ = try await store.sendThread(content: draft)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSending = false
        }
    }
}

public struct ShakeFeedbackIdentitySheet: View {
    @Bindable private var store: ShakeFeedbackStore
    @Environment(\.dismiss) private var dismiss
    @State private var nsec = ""
    @State private var error: String?

    public init(store: ShakeFeedbackStore) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Status", value: store.identity.publicKeyHex == nil ? "Not set up" : "Ready")
                    if let npub = store.identity.publicKeyNpub {
                        Text(npub)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                if !store.identity.usesHostIdentity {
                    Section("Use nsec") {
                        SecureField("nsec1...", text: $nsec)
                        Button("Import nsec") {
                            do {
                                try store.identity.importNsec(nsec)
                                error = nil
                                Task { await store.refresh() }
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .disabled(nsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section {
                        Button("Reset generated identity", role: .destructive) {
                            do {
                                try store.identity.resetGeneratedIdentity()
                                Task { await store.refresh() }
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Feedback Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
