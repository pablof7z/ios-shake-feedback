import Foundation
import Observation

@MainActor
@Observable
public final class ShakeFeedbackIdentityStore {
    public private(set) var publicKeyHex: String?
    public private(set) var publicKeyNpub: String?
    public private(set) var mode: ShakeFeedbackIdentityMode = .missing
    public private(set) var lastError: String?

    public var usesHostIdentity: Bool {
        mode == .hostApp
    }

    private let service: String
    private let keyAccount = "feedback-private-key"
    private let originAccount = "feedback-private-key-origin"
    private var keyPair: ShakeFeedbackKeyPair?
    private var hostSigner: (any ShakeFeedbackSigner)?
    private var generatedProfilePublishedForPubkey: String?

    public init(namespace: String) {
        self.service = "\(namespace).shake-feedback"
    }

    public var activeSigner: (any ShakeFeedbackSigner)? {
        get async {
            if let hostSigner, await hostSigner.publicKeyHex != nil {
                return hostSigner
            }
            if let keyPair {
                return ShakeFeedbackLocalSigner(keyPair: keyPair)
            }
            return nil
        }
    }

    public func start(hostSigner: (any ShakeFeedbackSigner)? = nil) async {
        self.hostSigner = hostSigner
        if let hostSigner, let pubkey = await hostSigner.publicKeyHex {
            publicKeyHex = pubkey
            publicKeyNpub = ShakeFeedbackBech32.encode(hrp: "npub", bytes: Data(sfHex: pubkey) ?? Data())
            mode = .hostApp
            return
        }
        do {
            if let privateKey = try ShakeFeedbackKeychain.read(service: service, account: keyAccount) {
                let pair = try ShakeFeedbackKeyPair(privateKeyHex: privateKey)
                set(pair: pair, mode: storedMode())
            } else {
                try generateFallbackIdentity()
            }
        } catch {
            lastError = error.localizedDescription
            mode = .missing
        }
    }

    public func refreshHostSigner(_ signer: (any ShakeFeedbackSigner)?) async {
        await start(hostSigner: signer)
    }

    public func importNsec(_ value: String) throws {
        let pair = try ShakeFeedbackKeyPair(secret: value)
        try ShakeFeedbackKeychain.save(pair.privateKeyHex, service: service, account: keyAccount)
        try ShakeFeedbackKeychain.save("nsec", service: service, account: originAccount)
        hostSigner = nil
        set(pair: pair, mode: .importedNsec)
    }

    public func resetGeneratedIdentity() throws {
        try ShakeFeedbackKeychain.delete(service: service, account: keyAccount)
        try ShakeFeedbackKeychain.delete(service: service, account: originAccount)
        try generateFallbackIdentity()
    }

    public func markGeneratedProfilePublished() {
        generatedProfilePublishedForPubkey = publicKeyHex
    }

    public var needsGeneratedProfilePublish: Bool {
        mode == .generated && publicKeyHex != nil && generatedProfilePublishedForPubkey != publicKeyHex
    }

    private func generateFallbackIdentity() throws {
        let pair = try ShakeFeedbackKeyPair.generate()
        try ShakeFeedbackKeychain.save(pair.privateKeyHex, service: service, account: keyAccount)
        try ShakeFeedbackKeychain.save("generated", service: service, account: originAccount)
        set(pair: pair, mode: .generated)
    }

    private func set(pair: ShakeFeedbackKeyPair, mode: ShakeFeedbackIdentityMode) {
        keyPair = pair
        publicKeyHex = pair.publicKeyHex
        publicKeyNpub = pair.npub
        self.mode = mode
        lastError = nil
    }

    private func storedMode() -> ShakeFeedbackIdentityMode {
        switch try? ShakeFeedbackKeychain.read(service: service, account: originAccount) {
        case "nsec": .importedNsec
        default: .generated
        }
    }
}
