import Foundation
import NetworkExtension
import Combine
import UIKit
import WidgetKit

/// App-side controller that drives the proxy in one of two modes:
///
/// - `.vpn`:   configures and starts a Packet Tunnel extension; the Go core
///             runs in that extension and is polled over IPC.
/// - `.local`: runs the Go core directly in this app process on loopback and
///             polls it in-process. A short UIKit background task keeps it
///             alive across the app→Telegram hop.
@MainActor
final class ProxyController: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)
    }

    @Published var state: State = .stopped
    @Published var settings: ProxySettings = .load()
    @Published var statsText: String = ""
    @Published var logLines: [String] = []
    /// Prefixed secret (dd…/ee…) reported by the running core; used for tg://.
    @Published var prefixedSecret: String?

    /// The mode the proxy is *currently running* in (may differ from
    /// `settings.backgroundMode`, which only takes effect on the next start).
    private(set) var activeMode: BackgroundMode?

    private var manager: NETunnelProviderManager?
    private var pollTask: Task<Void, Never>?
    private var statusObserver: NSObjectProtocol?
    private var bgObservers: [NSObjectProtocol] = []
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var isRunning: Bool { state == .running }

    init() {
        Task { await loadManager() }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshFromStatus() }
        }
    }

    deinit {
        if let statusObserver { NotificationCenter.default.removeObserver(statusObserver) }
        for o in bgObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: - Public control

    func toggle() {
        isRunning || state == .starting ? stop() : start()
    }

    func start() {
        state = .starting
        settings.save()
        switch settings.backgroundMode {
        case .vpn:   startVPN()
        case .local: startLocal()
        }
    }

    func stop() {
        state = .stopping
        switch activeMode {
        case .vpn:   manager?.connection.stopVPNTunnel()
        case .local: stopLocal()
        case .none:  state = .stopped
        }
        pollTask?.cancel()
        pollTask = nil
    }

    func saveSettings() {
        settings.save()
        // Push On Demand / port changes into the system VPN profile so they
        // take effect even when the user only edits Settings (no restart).
        applyVPNPreferences()
    }

    func regenerateSecret() {
        settings.secret = ProxySettings.randomSecret()
        settings.save()
    }

    /// tg:// link, preferring the prefixed secret reported by the running core.
    func telegramURL() -> URL? {
        settings.telegramProxyURL(prefixedSecretOverride: prefixedSecret)
    }

    func clearLogs() {
        logLines.removeAll()
        switch activeMode {
        case .local:
            ProxyCore.clearLogs()
        case .vpn:
            if let session = manager?.connection as? NETunnelProviderSession {
                try? session.sendProviderMessage(Data("clearLogs".utf8), responseHandler: nil)
            }
        case .none:
            break
        }
    }

    // MARK: - Local mode (in-app core)

    private func startLocal() {
        do {
            let prefixed = try ProxyCore.start(with: settings)
            prefixedSecret = prefixed
            activeMode = .local
            state = .running
            registerBackgroundHandling()
            startLocalPolling()
        } catch {
            activeMode = nil
            state = .failed(String(describing: error))
        }
    }

    private func stopLocal() {
        ProxyCore.stop()
        endBackgroundTask()
        unregisterBackgroundHandling()
        activeMode = nil
        state = .stopped
    }

    private func startLocalPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    guard let self, self.activeMode == .local else { return }
                    self.statsText = ProxyCore.statsRu()
                    let logs = ProxyCore.drainLogs()
                    if !logs.isEmpty { self.appendLogs(logs) }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // Keep the in-app proxy alive briefly when the app is backgrounded (e.g.
    // while the user is in Telegram confirming the proxy).
    private func registerBackgroundHandling() {
        guard bgObservers.isEmpty else { return }
        let nc = NotificationCenter.default
        bgObservers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.beginBackgroundTask() }
        })
        bgObservers.append(nc.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.endBackgroundTask() }
        })
    }

    private func unregisterBackgroundHandling() {
        for o in bgObservers { NotificationCenter.default.removeObserver(o) }
        bgObservers.removeAll()
    }

    private func beginBackgroundTask() {
        guard activeMode == .local, bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "tgwsproxy.local") { [weak self] in
            // Time expired — iOS is about to suspend us. Stop cleanly.
            Task { @MainActor in self?.stop() }
        }
    }

    private func endBackgroundTask() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }

    // MARK: - VPN mode (Packet Tunnel)

    private func loadManager() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let mgr = managers.first ?? NETunnelProviderManager()
        manager = mgr
        refreshFromStatus()
    }

    private func configuredManager() async throws -> NETunnelProviderManager {
        // Delegate to the shared helper so the On Demand rules and protocol
        // configuration stay consistent with what the App Intent / Control
        // Widget would write.
        let mgr = try await ProxyToggle.syncManager(settings: settings)
        manager = mgr
        return mgr
    }

    private func startVPN() {
        Task {
            do {
                let mgr = try await configuredManager()
                try mgr.connection.startVPNTunnel()
                activeMode = .vpn
                startVPNPolling()
            } catch {
                activeMode = nil
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Pushes the latest settings (notably On Demand toggle / domain list) to
    /// the system VPN preferences without starting the tunnel. Safe to call
    /// even when the proxy is currently stopped.
    func applyVPNPreferences() {
        Task {
            do {
                _ = try await ProxyToggle.syncManager(settings: settings)
            } catch {
                // Non-fatal: surface in logs but don't change the running state.
                appendLogs("Не удалось обновить VPN-профиль: \(error.localizedDescription)\n")
            }
        }
    }

    private func refreshFromStatus() {
        // Whatever happened to the tunnel — our action, On Demand auto-start,
        // a competing VPN that booted us off, or the user disabling the
        // profile in Settings — ask iOS to repaint the Control Center tile.
        // Cheap call; it just bumps a timeline so the widget extension's
        // ControlValueProvider is invoked again.
        reloadControlCenterTile()

        // Ignore VPN status changes while running locally — there is no tunnel.
        if activeMode == .local { return }
        guard let connection = manager?.connection else { state = .stopped; return }
        switch connection.status {
        case .connected:     state = .running; activeMode = .vpn; startVPNPolling()
        case .connecting:    state = .starting
        case .disconnecting: state = .stopping
        case .disconnected, .invalid:
            if case .failed = state { } else { state = .stopped }
            if activeMode == .vpn { activeMode = nil }
            pollTask?.cancel(); pollTask = nil
        case .reasserting:   state = .running
        @unknown default:    state = .stopped
        }
    }

    /// Forces the iOS 18 Control Center toggle to re-fetch its value. We call
    /// this from every state-changing path (NEVPNStatus observer, manual
    /// start/stop) so an external change (other VPN, Settings → VPN) doesn't
    /// leave the tile stuck on "running".
    private func reloadControlCenterTile() {
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: AppGroup.controlToggleKind)
        }
    }

    private func startVPNPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollVPNOnce()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func pollVPNOnce() async {
        guard
            let session = manager?.connection as? NETunnelProviderSession,
            session.status == .connected
        else { return }

        let response: Data? = await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data("status".utf8)) { data in
                    cont.resume(returning: data)
                }
            } catch {
                cont.resume(returning: nil)
            }
        }

        guard
            let response,
            let obj = try? JSONSerialization.jsonObject(with: response) as? [String: Any]
        else { return }

        if let stats = obj["stats"] as? String { statsText = stats }
        if let secret = obj["prefixedSecret"] as? String, !secret.isEmpty {
            prefixedSecret = secret
        }
        if let logs = obj["logs"] as? String, !logs.isEmpty {
            appendLogs(logs)
        }
    }

    // MARK: - Shared

    private func appendLogs(_ text: String) {
        let incoming = text.split(separator: "\n").map(String.init)
        logLines.append(contentsOf: incoming)
        if logLines.count > 1000 {
            logLines.removeFirst(logLines.count - 1000)
        }
    }
}
