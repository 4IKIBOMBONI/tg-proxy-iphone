import Foundation
import NetworkExtension

/// Headless controller for the Packet Tunnel proxy. Lives in the shared module
/// so it can be used from anywhere that has the NetworkExtension entitlement
/// and access to our App Group:
///
/// - the main app's `ProxyController` (UI)
/// - the App Intent invoked from Siri / Shortcuts / Lock Screen / Home Screen
/// - the iOS 18 Control Center widget
///
/// It does **not** touch UIKit or SwiftUI and never starts the in-process
/// "local" mode — `AppIntent`s and widgets run in short-lived background
/// processes that iOS would kill immediately, so the only sensible way to
/// toggle the proxy from outside the main app is the VPN tunnel.
///
/// All entry points are async and safe to call from any actor.
public enum ProxyToggle {

    public enum ToggleError: Error, LocalizedError {
        case managerUnavailable
        case startFailed(String)
        case stopFailed(String)

        public var errorDescription: String? {
            switch self {
            case .managerUnavailable:    return "VPN-профиль недоступен"
            case .startFailed(let m):    return "Не удалось запустить прокси: \(m)"
            case .stopFailed(let m):     return "Не удалось остановить прокси: \(m)"
            }
        }
    }

    /// Loads (or creates) our `NETunnelProviderManager`, applies the latest
    /// settings from the App Group, and persists it to system preferences.
    ///
    /// Reused by both `start` and by the UI when the user toggles On Demand,
    /// so the user always gets a single coherent profile.
    @discardableResult
    public static func syncManager(
        settings: ProxySettings = .load()
    ) async throws -> NETunnelProviderManager {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let mgr = managers.first ?? NETunnelProviderManager()

        let proto = (mgr.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppGroup.tunnelBundleIdentifier
        proto.serverAddress = "127.0.0.1:\(settings.port)"
        proto.providerConfiguration = ["port": settings.port]
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "TG WS Proxy"
        mgr.isEnabled = true

        // On Demand rules — see ProxyOnDemand for the actual rule construction.
        let rules = ProxyOnDemand.buildRules(from: settings)
        mgr.onDemandRules = rules
        mgr.isOnDemandEnabled = settings.onDemandEnabled && !rules.isEmpty

        try await mgr.saveToPreferences()
        try await mgr.loadFromPreferences()
        return mgr
    }

    /// Returns true if a VPN-mode tunnel is currently connected (or connecting).
    public static func isRunning() async -> Bool {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let mgr = managers.first else { return false }
        switch mgr.connection.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }

    /// Starts the proxy in VPN mode. If the user has the app currently set to
    /// `.local` mode this still works (it just brings up the tunnel as well);
    /// the UI controller treats the active mode independently. The intent here
    /// is "the user explicitly asked the system-level toggle to turn on" — we
    /// honour that even if the app would normally run in-process.
    public static func start() async throws {
        let settings = ProxySettings.load()
        let mgr = try await syncManager(settings: settings)
        do {
            try mgr.connection.startVPNTunnel()
        } catch {
            throw ToggleError.startFailed(error.localizedDescription)
        }
        // Wait briefly for the connection to come up so Siri / Control Center
        // can show a meaningful "result" state.
        await waitFor(connection: mgr.connection, target: [.connected]) // best effort
    }

    public static func stop() async throws {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        guard let mgr = managers.first else { return }
        // If On Demand is on, just stopping the tunnel will let iOS re-trigger
        // it on the next matching DNS lookup. Users almost always mean "really
        // stop it" when they tap a stop control, so we flip On Demand off too.
        // The next explicit start (or save in Settings) re-enables it.
        if mgr.isOnDemandEnabled {
            mgr.isOnDemandEnabled = false
            try? await mgr.saveToPreferences()
            try? await mgr.loadFromPreferences()
        }
        mgr.connection.stopVPNTunnel()
        await waitFor(connection: mgr.connection, target: [.disconnected, .invalid])
    }

    /// Convenience used by the Control Center widget and Shortcuts toggle.
    /// Returns the new running state.
    @discardableResult
    public static func toggle() async throws -> Bool {
        if await isRunning() {
            try await stop()
            return false
        } else {
            try await start()
            return true
        }
    }

    // MARK: - Helpers

    /// Polls the connection status for up to ~5s waiting for `target`. We deliberately
    /// avoid relying on NotificationCenter here because the App Intent process may
    /// terminate before the next runloop pass.
    private static func waitFor(connection: NEVPNConnection,
                                target: Set<NEVPNStatus>,
                                timeoutMs: Int = 5_000) async {
        let stepMs = 100
        var elapsed = 0
        while elapsed < timeoutMs {
            if target.contains(connection.status) { return }
            try? await Task.sleep(nanoseconds: UInt64(stepMs) * 1_000_000)
            elapsed += stepMs
        }
    }
}
