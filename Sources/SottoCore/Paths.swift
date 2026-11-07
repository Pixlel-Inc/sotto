import Foundation

public enum Sotto {
    public static let version = "0.1.0"
}

/// Where Sotto keeps things. Recordings and the inbox live in a folder you can
/// browse (~/Documents/Sotto by default, or $SOTTO_HOME). The search index and
/// settings live in Application Support.
public struct SottoPaths: Sendable {
    public let home: URL
    public let support: URL

    public var recordings: URL { home.appendingPathComponent("Recordings", isDirectory: true) }
    public var inbox: URL { home.appendingPathComponent("Inbox", isDirectory: true) }
    public var indexDB: URL { support.appendingPathComponent("index.sqlite") }
    public var configFile: URL { support.appendingPathComponent("config.json") }
    public var voicesFile: URL { support.appendingPathComponent("voices.json") }

    public init(home: URL, support: URL) {
        self.home = home
        self.support = support
    }

    public static func standard() -> SottoPaths {
        let vars = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        let home: URL
        if let custom = vars["SOTTO_HOME"], !custom.isEmpty {
            home = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            home = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("Sotto", isDirectory: true)
        }
        let support: URL
        if let custom = vars["SOTTO_SUPPORT"], !custom.isEmpty {
            support = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            support = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Sotto", isDirectory: true)
        }
        return SottoPaths(home: home, support: support)
    }

    public func ensure() throws {
        let fm = FileManager.default
        for dir in [home, recordings, inbox, support] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
