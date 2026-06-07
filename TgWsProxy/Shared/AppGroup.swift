import Foundation

/// Identifiers shared between the app and the Packet Tunnel extension.
///
/// These MUST match the values in `project.yml` (App Group capability and the
/// bundle identifiers). If you change the App Group id, update it in all three
/// places: here, the app entitlements, and the tunnel entitlements.
enum AppGroup {
    /// App Group container shared by the app and the network extension.
    static let identifier = "group.com.tgwsproxy.shared"

    /// Bundle identifier of the Packet Tunnel provider extension.
    static let tunnelBundleIdentifier = "com.tgwsproxy.app.tunnel"

    /// Shared UserDefaults backed by the App Group container.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    /// Shared container directory (used by the Go core for its CloudFlare
    /// domain cache, and for the logs/stats hand-off file).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// File the extension writes the latest log snapshot to.
    static var logFileURL: URL? {
        containerURL?.appendingPathComponent("proxy.log")
    }
}
