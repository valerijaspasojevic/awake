// Types and paths shared by the menu bar app and the `awake` command-line tool.
import Foundation

enum Awake {
    static let version = "1.0.0"
    static let bundleID = "io.github.valerijaspasojevic.awake"
    static let commandNote = Notification.Name("io.github.valerijaspasojevic.awake.command")
    static let repoURL = URL(string: "https://github.com/valerijaspasojevic/awake")!
    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Awake")
    }
    static var statusURL: URL { supportDir.appendingPathComponent("status.json") }

    /// Process names treated as AI agents. Matched against the process name and its first arguments.
    static let defaultAgents = ["claude", "codex", "cursor-agent", "gemini", "aider", "goose", "opencode", "amp", "qwen", "crush"]

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// A request from the CLI to the running app (sent as a distributed notification).
struct Command: Codable {
    var id = UUID().uuidString
    var action: String           // on, off, hold, release, agent-mode, agents-add, agents-remove, agents-reset, ping
    var name: String? = nil
    var minutes: Int? = nil
    var pid: Int32? = nil
    var values: [String]? = nil
    var flag: Bool? = nil
}

struct AgentInfo: Codable { var name: String; var pid: Int32; var working: Bool; var cpuPercent: Double }
struct HoldInfo: Codable { var name: String; var until: Date; var pid: Int32? }

/// Snapshot the app writes to ~/Library/Application Support/Awake/status.json on every change.
struct Status: Codable {
    var pid: Int32
    var version: String
    var updated: Date
    var lastCommandID: String?
    var awake: Bool
    var screenOn: Bool
    var summary: String
    var paused: String?
    var manual: Bool
    var manualUntil: Date?
    var agentMode: Bool
    var agents: [AgentInfo]
    var holds: [HoldInfo]
    var watched: [String]
    var onlyWhenPluggedIn: Bool
    var maxHours: Int
    var keepScreenOnForAgents: Bool
    var ignoreIdleAgents: Bool

    static func read() -> Status? {
        guard let data = try? Data(contentsOf: Awake.statusURL),
              let s = try? Awake.decoder.decode(Status.self, from: data),
              kill(s.pid, 0) == 0 || errno == EPERM else { return nil }
        return s
    }
}

func formatTime(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) }
