import Foundation

/// Canonical daemon paths under the user home. All defaults live here so the
/// on-disk layout stays in one place; injection points in services are unchanged.
enum Paths {
    static func stateDirectoryURL(home: String? = nil) -> URL {
        URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".local/state/\(AppIdentity.dataDirectoryName)", isDirectory: true)
    }

    static func logDirectoryURL(home: String? = nil) -> URL {
        stateDirectoryURL(home: home).appendingPathComponent("logs", isDirectory: true)
    }

    static func configFileURL(home: String? = nil) -> URL {
        URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".config/\(AppIdentity.dataDirectoryName)/config.json")
    }

    /// SQLite database file (stage 3): ~/.local/share/slam/agent.sqlite
    static func databaseURL(home: String? = nil) -> URL {
        URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".local/share/\(AppIdentity.dataDirectoryName)/agent.sqlite", isDirectory: false)
    }

    /// Release binary installed by `install.sh` (LaunchAgent ProgramArguments).
    static func installedBinaryURL(home: String? = nil) -> URL {
        URL(fileURLWithPath: home ?? FileManager.default.homeDirectoryForCurrentUser.path)
            .appendingPathComponent(".local/bin/\(AppIdentity.cliName)", isDirectory: false)
    }
}
