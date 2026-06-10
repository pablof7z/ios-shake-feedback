# ShakeFeedbackKit

ShakeFeedbackKit is a Swift Package for adding an in-app feedback flow to iOS apps. It opens a SwiftUI feedback sheet from a shake gesture, signs feedback as Nostr events, publishes it to a configured relay, and renders project feedback threads back inside the app.

The package is built for iOS 17+ and uses SwiftUI, Observation, URLSession WebSockets, Keychain storage, Schnorr signatures, and a small Rust core that is shipped as an XCFramework.

## What It Provides

- A shake detector view modifier for SwiftUI apps.
- A ready-made feedback sheet with thread list, compose, conversation, reply, and identity screens.
- A `ShakeFeedbackStore` observable model that loads, reduces, filters, subscribes to, and sends feedback.
- A Nostr relay client with support for fetches, subscriptions, publishing, `OK` handling, relay `AUTH` challenges, and timeouts.
- Local feedback identities that are generated into Keychain, imported from `nsec`, or supplied by the host app through `ShakeFeedbackSigner`.
- A Rust core, exposed through `ShakeFeedbackCore.xcframework`, for reducing raw Nostr events into project threads and generating stable fallback profiles.

## Package Layout

```text
Sources/ShakeFeedbackKit/      Swift package source
Frameworks/                   Bundled Rust XCFramework used by SwiftPM
include/                      C headers for the Rust FFI
rust/                         Rust core source and tests
scripts/build-xcframework.sh  Rebuilds the Rust XCFramework for device and simulator
```

## Installation

Add the package in Xcode or in `Package.swift`:

```swift
.package(url: "https://github.com/pablof7z/ios-shake-feedback.git", from: "1.0.0")
```

Then depend on the product:

```swift
.product(name: "ShakeFeedbackKit", package: "ios-shake-feedback")
```

Consumers do not need Rust installed. The prebuilt `Frameworks/ShakeFeedbackCore.xcframework` is included in the package.

## Basic Integration

Create one long-lived `ShakeFeedbackStore`, start it when your app launches, attach the shake detector to your root view, and present `ShakeFeedbackSheet` when the detector fires.

```swift
import ShakeFeedbackKit
import SwiftUI

@main
struct ExampleApp: App {
    @State private var feedbackStore: ShakeFeedbackStore
    @State private var showsFeedback = false

    init() {
        let config = ShakeFeedbackConfig(
            appName: "Example",
            clientTag: "example-ios",
            projectATag: "31933:<project-pubkey>:example",
            agentPubkey: "<optional-agent-pubkey>"
        )
        _feedbackStore = State(initialValue: ShakeFeedbackStore(config: config))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    await feedbackStore.start()
                }
                .shakeFeedbackDetector {
                    showsFeedback = true
                }
                .sheet(isPresented: $showsFeedback) {
                    ShakeFeedbackSheet(store: feedbackStore)
                }
        }
    }
}
```

`projectATag` is the Nostr address tag that ties feedback to one project. Keep it stable across app releases so old and new feedback remain in the same project thread list.

## Configuration

`ShakeFeedbackConfig` controls the project and relay behavior:

```swift
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
)
```

- `appName` is used in the generated feedback profile.
- `clientTag` is written into outgoing feedback events and also namespaces the local Keychain identity.
- `projectATag` is added as an `a` tag to feedback events and used when querying project threads.
- `agentPubkey` is optional. When present, new feedback threads tag the agent so it can discover and reply.
- `feedbackRelayURL` is the primary relay used for feedback events.
- `profileRelayURLs` are queried for Nostr kind `0` profile metadata.
- `showEveryoneByDefault` changes the initial thread filter from "Mine" to "Everyone".

## Identities

By default the package creates a local Nostr identity, stores the private key in Keychain, and publishes a generated profile the first time feedback is sent. Users can also import an `nsec` from the identity sheet or reset the generated identity.

Apps that already own a Nostr identity can provide a signer instead:

```swift
struct AppFeedbackSigner: ShakeFeedbackSigner {
    var publicKeyHex: String? {
        get async { "<hex-pubkey>" }
    }

    func signFeedbackEvent(_ draft: ShakeFeedbackEventDraft) async throws -> ShakeFeedbackEvent {
        fatalError("Sign a Nostr event with your app's existing key management.")
    }
}

await feedbackStore.start(hostSigner: AppFeedbackSigner())
```

When a host signer is active, the identity UI is hidden and feedback is signed with the host app identity.

## Nostr Behavior

User feedback is published as kind `1` events tagged with the configured project `a` tag and client tag. Replies include an `e` root marker, and new threads or replies can include a `p` tag for the configured agent or the last other participant.

The store also understands kind `513` project metadata events. The Rust reducer uses those events to update thread title, summary, status label, and last activity while keeping the app-side Swift code focused on relay IO and UI state.

If a relay requires NIP-42 authentication, the relay client responds to `AUTH` challenges by signing a kind `22242` auth event with the active feedback signer.

## Development

Run the Rust core tests:

```sh
cargo test --manifest-path rust/Cargo.toml
```

Rebuild the bundled XCFramework after changing Rust code:

```sh
./scripts/build-xcframework.sh
```

The build script compiles Rust for `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`, combines simulator slices with `lipo`, and writes `Frameworks/ShakeFeedbackCore.xcframework`.

For Swift changes, validate the package in an iOS app or Xcode scheme that depends on `ShakeFeedbackKit`. The package manifest itself uses Swift tools version 6.0 and declares iOS 17 as the minimum platform.
