import Foundation

/// Non-secret runtime configuration (model name, allowlist, limits).
/// Secrets never live here: the bot token goes to macOS Keychain only.
struct AgentConfig: Codable, Sendable, Equatable {
    var telegramAllowlist: [Int64]
    var model: String
    var workingDir: String
    var maxContextMessages: Int
    var idleUnloadMinutes: Int
    var ollamaURL: String?
    var systemPrompt: String?
    var contextBudgetChars: Int?
    /// Disk quota override in bytes (tests / power users); nil = auto per FR-19.
    var storageQuotaBytes: Int?
    /// Extra destructive-command regexes (FR-23) on top of the built-in list.
    var destructivePatterns: [String]?
    /// Per-command wall-clock timeout in seconds.
    var commandTimeoutSeconds: Int?
    /// HITL button lifetime in seconds (spec says 10 minutes).
    var confirmationTimeoutSeconds: Int?
    /// false → commands run without sandbox-exec (tests / explicit opt-out).
    var sandboxEnabled: Bool?
    /// FR-21: use Ollama's native `tools` API instead of only the ```run
    /// fence marker. Defaults to true — qwen2.5's Ollama template ships a
    /// Hermes-style tool-call parser, and the fence marker stays wired as an
    /// automatic fallback whenever a turn has no tool_calls, so there is no
    /// behavior regression risk from defaulting this on.
    var useNativeTools: Bool?

    enum CodingKeys: String, CodingKey {
        case telegramAllowlist = "telegram_allowlist"
        case model
        case workingDir = "working_dir"
        case maxContextMessages = "max_context_messages"
        case idleUnloadMinutes = "idle_unload_minutes"
        case ollamaURL = "ollama_url"
        case systemPrompt = "system_prompt"
        case contextBudgetChars = "context_budget_chars"
        case storageQuotaBytes = "storage_quota_bytes"
        case destructivePatterns = "destructive_patterns"
        case commandTimeoutSeconds = "command_timeout_seconds"
        case confirmationTimeoutSeconds = "confirmation_timeout_seconds"
        case sandboxEnabled = "sandbox_enabled"
        case useNativeTools = "use_native_tools"
    }

    static let `default` = AgentConfig(
        telegramAllowlist: [],
        model: "qwen2.5:7b",
        workingDir: "~/.local/share/\(AppIdentity.dataDirectoryName)/workspace",
        maxContextMessages: 20,
        idleUnloadMinutes: 10,
        ollamaURL: nil,
        systemPrompt: nil,
        contextBudgetChars: nil,
        storageQuotaBytes: nil
    )

    /// The first allowlist entry is the owner: the only user allowed to run /allow and /deny.
    var ownerId: Int64? { telegramAllowlist.first }

    /// Falls back per-key so configs written by older stages keep loading.
    init(
        telegramAllowlist: [Int64],
        model: String,
        workingDir: String,
        maxContextMessages: Int,
        idleUnloadMinutes: Int,
        ollamaURL: String? = nil,
        systemPrompt: String? = nil,
        contextBudgetChars: Int? = nil,
        storageQuotaBytes: Int? = nil
    ) {
        self.telegramAllowlist = telegramAllowlist
        self.model = model
        self.workingDir = workingDir
        self.maxContextMessages = maxContextMessages
        self.idleUnloadMinutes = idleUnloadMinutes
        self.ollamaURL = ollamaURL
        self.systemPrompt = systemPrompt
        self.contextBudgetChars = contextBudgetChars
        self.storageQuotaBytes = storageQuotaBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        telegramAllowlist = try c.decode([Int64].self, forKey: .telegramAllowlist)
        model = try c.decode(String.self, forKey: .model)
        let d = Self.default
        workingDir = try c.decodeIfPresent(String.self, forKey: .workingDir) ?? d.workingDir
        maxContextMessages = try c.decodeIfPresent(Int.self, forKey: .maxContextMessages) ?? d.maxContextMessages
        idleUnloadMinutes = try c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
        ollamaURL = try c.decodeIfPresent(String.self, forKey: .ollamaURL)
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        contextBudgetChars = try c.decodeIfPresent(Int.self, forKey: .contextBudgetChars)
            ?? d.contextBudgetChars
        storageQuotaBytes = try c.decodeIfPresent(Int.self, forKey: .storageQuotaBytes)
        destructivePatterns = try c.decodeIfPresent([String].self, forKey: .destructivePatterns)
        commandTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .commandTimeoutSeconds)
        confirmationTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .confirmationTimeoutSeconds)
        sandboxEnabled = try c.decodeIfPresent(Bool.self, forKey: .sandboxEnabled)
        useNativeTools = try c.decodeIfPresent(Bool.self, forKey: .useNativeTools)
    }

    /// Character budget for FTS-injected fragments; nil disables the injection.
    var resolvedContextBudgetChars: Int? {
        contextBudgetChars.flatMap { $0 > 0 ? $0 : nil }
    }

    var resolvedOllamaURL: URL {
        URL(string: ollamaURL ?? "http://127.0.0.1:11434") ?? URL(string: "http://127.0.0.1:11434")!
    }

    // Stage 4 resolution helpers.

    var resolvedCommandTimeout: TimeInterval {
        TimeInterval(max(1, commandTimeoutSeconds ?? 30))
    }

    var resolvedConfirmationTimeout: TimeInterval {
        TimeInterval(max(1, confirmationTimeoutSeconds ?? 600))
    }

    var resolvedSandboxEnabled: Bool { sandboxEnabled ?? true }
    var resolvedUseNativeTools: Bool { useNativeTools ?? true }

    /// Absolute workspace path (config stores `~`-relative by default).
    var resolvedWorkingDirPath: String {
        let expanded: String
        if workingDir.hasPrefix("~/") {
            expanded = NSString(string: workingDir).expandingTildeInPath
        } else if workingDir == "~" {
            expanded = NSHomeDirectory()
        } else {
            expanded = workingDir
        }
        var canonical = expanded
        if let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.pathComponents as [String]? {
            canonical = "/" + standardized.dropFirst().joined(separator: "/")
        }
        return canonical
    }

    static func configFileURL() -> URL {
        Paths.configFileURL()
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case notWritable(String)

    var description: String {
        switch self {
        case .invalidJSON(let path): return "config is not valid JSON: \(path)"
        case .notWritable(let path): return "cannot write config: \(path)"
        }
    }
}

enum ConfigStore {
    /// Loads config or creates a default one. Returns config plus a flag whether it was created now.
    static func loadOrCreate(url: URL = AgentConfig.configFileURL()) throws -> (AgentConfig, created: Bool) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            do {
                let config = try JSONDecoder().decode(AgentConfig.self, from: data)
                return (config, false)
            } catch {
                throw ConfigError.invalidJSON(url.path)
            }
        }
        let config = AgentConfig.default
        try write(config, url: url)
        return (config, true)
    }

    static func write(_ config: AgentConfig, url: URL = AgentConfig.configFileURL()) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConfigError.notWritable(url.path)
        }
    }
}
