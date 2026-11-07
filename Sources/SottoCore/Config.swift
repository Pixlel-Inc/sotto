import Foundation
import Security

public struct SottoConfig: Codable, Sendable {
    /// Bearer token for the local HTTP API. Generated on first run.
    public var apiToken: String
    public var port: Int
    /// Label used for the microphone track ("Me" until you set your name).
    public var ownerName: String
    /// Show a reminder to tell people before a recording starts.
    public var consentReminder: Bool
    /// Text copied to the clipboard by "Copy recording notice".
    public var consentNotice: String
    /// Parakeet model: "v3" (multilingual, default), "v2" (English only) or "ultra".
    public var asrModel: String
    /// Cosine similarity needed to put a remembered name on a new speaker.
    public var voiceMatchThreshold: Float

    public static let defaultNotice =
        "Quick heads up: I record my calls so I can take notes. The recording stays on my computer and is transcribed there. Let me know if you would rather I did not."

    public init() {
        apiToken = SottoConfig.makeToken()
        port = 47820
        ownerName = "Me"
        consentReminder = true
        consentNotice = SottoConfig.defaultNotice
        asrModel = "v3"
        voiceMatchThreshold = 0.72
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SottoConfig()
        apiToken = try c.decodeIfPresent(String.self, forKey: .apiToken) ?? d.apiToken
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        ownerName = try c.decodeIfPresent(String.self, forKey: .ownerName) ?? d.ownerName
        consentReminder = try c.decodeIfPresent(Bool.self, forKey: .consentReminder) ?? d.consentReminder
        consentNotice = try c.decodeIfPresent(String.self, forKey: .consentNotice) ?? d.consentNotice
        asrModel = try c.decodeIfPresent(String.self, forKey: .asrModel) ?? d.asrModel
        voiceMatchThreshold = try c.decodeIfPresent(Float.self, forKey: .voiceMatchThreshold) ?? d.voiceMatchThreshold
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return "sotto_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Loads the config, creating it (with a fresh token) if it does not exist yet.
    public static func load(_ paths: SottoPaths) throws -> SottoConfig {
        try paths.ensure()
        if let data = try? Data(contentsOf: paths.configFile) {
            return try JSONDecoder().decode(SottoConfig.self, from: data)
        }
        let config = SottoConfig()
        try config.save(paths)
        return config
    }

    public func save(_ paths: SottoPaths) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: paths.configFile, options: .atomic)
        // The token guards the local API, so keep the file private to this user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
    }
}
