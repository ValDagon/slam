import Foundation

/// Product identity. Display name is **S.L.A.M**; the on-disk / launchd / CLI
/// token is `slam` (dots in a Unix binary name break `pgrep -x` and PATH habits).
/// The Swift module stays `SwiftAgent` so imports and actors do not churn.
enum AppIdentity: Sendable {
    static let displayName = "S.L.A.M"
    static let expansion = "Swift Light Agent for Mac"
    static let cliName = "slam"
    static let dataDirectoryName = "slam"
    static let keychainService = "com.local.slam"
    /// Pre-rebrand Keychain service. `load` / `delete` still probe it.
    static let legacyKeychainService = "com.local.swift-agent"
    static let logFileName = "slam.log"
    static let loggerQueueLabel = "com.local.slam.logger"
    static let quietStderrEnv = "SLAM_QUIET_STDERR"
    static let legacyQuietStderrEnv = "SWIFT_AGENT_QUIET_STDERR"
    static let keychainAccessLabel = "S.L.A.M telegram-bot-token"

    /// First line of `/status` and the Telegram HTML `<pre>` detector.
    static var versionLine: String { "\(displayName) v\(AppVersion.string)" }
}
