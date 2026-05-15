import CryptoKit
import Foundation
import P256K

public protocol ShakeFeedbackSigner: Sendable {
    var publicKeyHex: String? { get async }
    func signFeedbackEvent(_ draft: ShakeFeedbackEventDraft) async throws -> ShakeFeedbackEvent
}

struct ShakeFeedbackKeyPair: Sendable, Equatable {
    let privateKeyHex: String
    let publicKeyHex: String

    init(privateKeyHex: String) throws {
        let trimmed = privateKeyHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let data = Data(sfHex: trimmed), data.count == 32 else {
            throw ShakeFeedbackError.invalidIdentity("Invalid Nostr private key.")
        }
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: data)
        self.privateKeyHex = trimmed
        self.publicKeyHex = Data(key.xonly.bytes).sfHex
    }

    init(nsec: String) throws {
        let (hrp, bytes) = try ShakeFeedbackBech32.decode(nsec.trimmingCharacters(in: .whitespacesAndNewlines))
        guard hrp == "nsec", bytes.count == 32 else {
            throw ShakeFeedbackError.invalidIdentity("Invalid nsec.")
        }
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: bytes)
        self.privateKeyHex = bytes.sfHex
        self.publicKeyHex = Data(key.xonly.bytes).sfHex
    }

    init(secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("nsec1") {
            try self.init(nsec: trimmed)
        } else {
            try self.init(privateKeyHex: trimmed)
        }
    }

    static func generate() throws -> ShakeFeedbackKeyPair {
        let key = try P256K.Schnorr.PrivateKey()
        return ShakeFeedbackKeyPair(
            privateKeyHex: Data(key.dataRepresentation).sfHex,
            publicKeyHex: Data(key.xonly.bytes).sfHex
        )
    }

    private init(privateKeyHex: String, publicKeyHex: String) {
        self.privateKeyHex = privateKeyHex
        self.publicKeyHex = publicKeyHex
    }

    var nsec: String {
        ShakeFeedbackBech32.encode(hrp: "nsec", bytes: Data(sfHex: privateKeyHex) ?? Data())
    }

    var npub: String {
        ShakeFeedbackBech32.encode(hrp: "npub", bytes: Data(sfHex: publicKeyHex) ?? Data())
    }

    func sign(_ draft: ShakeFeedbackEventDraft) throws -> ShakeFeedbackEvent {
        let id = try ShakeFeedbackEventID.compute(
            pubkey: publicKeyHex,
            createdAt: draft.createdAt,
            kind: draft.kind,
            tags: draft.tags,
            content: draft.content
        )
        guard let idData = Data(sfHex: id),
              let privateKeyData = Data(sfHex: privateKeyHex),
              idData.count == 32,
              privateKeyData.count == 32
        else {
            throw ShakeFeedbackError.invalidEvent("Could not prepare Schnorr signing bytes.")
        }
        let signingKey = try P256K.Schnorr.PrivateKey(dataRepresentation: privateKeyData)
        var messageBytes = [UInt8](idData)
        var auxiliaryRandomness = [UInt8](repeating: 0, count: 32)
        let signature = try signingKey.signature(message: &messageBytes, auxiliaryRand: &auxiliaryRandomness)
        return ShakeFeedbackEvent(
            id: id,
            pubkey: publicKeyHex,
            createdAt: draft.createdAt,
            kind: draft.kind,
            tags: draft.tags,
            content: draft.content,
            sig: Data(signature.dataRepresentation).sfHex
        )
    }
}

struct ShakeFeedbackLocalSigner: ShakeFeedbackSigner {
    let keyPair: ShakeFeedbackKeyPair

    var publicKeyHex: String? {
        get async { keyPair.publicKeyHex }
    }

    func signFeedbackEvent(_ draft: ShakeFeedbackEventDraft) async throws -> ShakeFeedbackEvent {
        try keyPair.sign(draft)
    }
}

enum ShakeFeedbackEventID {
    static func compute(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String
    ) throws -> String {
        let value: [Any] = [0, pubkey, createdAt, kind, tags, content]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])
        return Data(SHA256.hash(data: data)).sfHex
    }
}

enum ShakeFeedbackBech32 {
    enum DecodeError: Error {
        case invalid
    }

    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let charsetIndex: [Character: Int] = {
        Dictionary(uniqueKeysWithValues: charset.enumerated().map { ($1, $0) })
    }()

    static func encode(hrp: String, bytes: Data) -> String {
        let fiveBit = convertBits(Array(bytes), from: 8, to: 5, pad: true) ?? []
        let combined = fiveBit + createChecksum(hrp: hrp, data: fiveBit)
        return "\(hrp)1" + combined.map { String(charset[$0]) }.joined()
    }

    static func decode(_ encoded: String) throws -> (hrp: String, bytes: Data) {
        let lower = encoded.lowercased()
        guard encoded == lower || encoded == encoded.uppercased(),
              let separator = lower.lastIndex(of: "1")
        else { throw DecodeError.invalid }
        let hrp = String(lower[..<separator])
        let dataPart = lower[lower.index(after: separator)...]
        guard !hrp.isEmpty, dataPart.count >= 6 else { throw DecodeError.invalid }
        var values: [Int] = []
        for character in dataPart {
            guard let value = charsetIndex[character] else { throw DecodeError.invalid }
            values.append(value)
        }
        guard polymod(hrpExpand(hrp) + values) == 1 else { throw DecodeError.invalid }
        guard let bytes = convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false) else {
            throw DecodeError.invalid
        }
        return (hrp, Data(bytes))
    }

    private static func polymod(_ values: [Int]) -> Int {
        let generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var checksum = 1
        for value in values {
            let top = checksum >> 25
            checksum = ((checksum & 0x1ffffff) << 5) ^ value
            for index in 0..<5 where ((top >> index) & 1) != 0 {
                checksum ^= generators[index]
            }
        }
        return checksum
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        let scalars = Array(hrp.unicodeScalars)
        return scalars.map { Int($0.value) >> 5 } + [0] + scalars.map { Int($0.value) & 31 }
    }

    private static func createChecksum(hrp: String, data: [Int]) -> [Int] {
        let values = hrpExpand(hrp) + data + Array(repeating: 0, count: 6)
        let checksum = polymod(values) ^ 1
        return (0..<6).map { (checksum >> (5 * (5 - $0))) & 31 }
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [Int]? {
        var accumulator = 0
        var bits = 0
        var output: [Int] = []
        let maxValue = (1 << to) - 1
        let maxAccumulator = (1 << (from + to - 1)) - 1
        for value in data {
            let intValue = Int(value)
            guard intValue >> from == 0 else { return nil }
            accumulator = ((accumulator << from) | intValue) & maxAccumulator
            bits += from
            while bits >= to {
                bits -= to
                output.append((accumulator >> bits) & maxValue)
            }
        }
        if pad, bits > 0 {
            output.append((accumulator << (to - bits)) & maxValue)
        } else if !pad, (bits >= from || ((accumulator << (to - bits)) & maxValue) != 0) {
            return nil
        }
        return output
    }

    private static func convertBits(_ data: [Int], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        var output: [UInt8] = []
        let maxValue = (1 << to) - 1
        let maxAccumulator = (1 << (from + to - 1)) - 1
        for value in data {
            guard value >= 0, value >> from == 0 else { return nil }
            accumulator = ((accumulator << from) | value) & maxAccumulator
            bits += from
            while bits >= to {
                bits -= to
                output.append(UInt8((accumulator >> bits) & maxValue))
            }
        }
        if pad, bits > 0 {
            output.append(UInt8((accumulator << (to - bits)) & maxValue))
        } else if !pad, (bits >= from || ((accumulator << (to - bits)) & maxValue) != 0) {
            return nil
        }
        return output
    }
}

extension Data {
    init?(sfHex hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let nextIndex = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        self = Data(bytes)
    }

    var sfHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

