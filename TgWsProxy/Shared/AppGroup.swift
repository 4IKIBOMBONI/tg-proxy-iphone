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
    ///
    /// We cannot derive it from `Bundle.main.bundleIdentifier`, because that
    /// returns the *current* binary's id — fine in the main app, but in the
    /// Control Center extension it would yield `…control.tunnel`, which never
    /// exists. So we read it from a build-time Info.plist key (`APP_ID_BASE`)
    /// that every target inherits from `project.yml` and falls back to a
    /// derived value only as a last resort.
    static var tunnelBundleIdentifier: String {
        if let base = Bundle.main.object(forInfoDictionaryKey: "APP_ID_BASE") as? String,
           !base.isEmpty {
            return base + ".tunnel"
        }
        // Fallback: works in the main app where bundleIdentifier == APP_ID_BASE.
        let me = Bundle.main.bundleIdentifier ?? "com.tgwsproxy.mobileapp"
        // Strip any extension suffix (".tunnel", ".control") so we always
        // resolve to the host app id even when called from an extension that
        // was built without the APP_ID_BASE Info.plist key.
        let base: String
        if me.hasSuffix(".control") {
            base = String(me.dropLast(".control".count))
        } else if me.hasSuffix(".tunnel") {
            base = String(me.dropLast(".tunnel".count))
        } else {
            base = me
        }
        return base + ".tunnel"
    }

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

    /// Control Center widget "kind" identifier. Lives in the shared module so
    /// both the main app (`ControlCenter.shared.reloadControls(ofKind:)`) and
    /// the widget extension (`StaticControlConfiguration(kind:)`) use the
    /// exact same string.
    static let controlToggleKind = "com.tgwsproxy.controls.toggle"
}
