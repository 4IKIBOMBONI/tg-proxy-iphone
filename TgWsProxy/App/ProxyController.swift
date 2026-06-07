import Foundation
import NetworkExtension
import Combine

/// App-side controller that drives the Packet Tunnel manager and surfaces the
/// proxy state to SwiftUI. The proxy itself runs in the extension; this class
/// only configures it, starts/stops it, and polls it for stats/logs.
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

    private var manager: NETunnelProviderManager?
    private var pollTask: Task<Void, Never>?
    private var statusObserver: NSObjectProtocol?

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
    }

    // MARK: - Manager setup

    private func loadManager() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        let mgr = managers.first ?? NETunnelProviderManager()
        manager = mgr
        refreshFromStatus()
    }

    private func configuredManager() -> NETunnelProviderManager {
        let mgr = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppGroup.tunnelBundleIdentifier
        // Loopback "server" — the address is cosmetic; the real listener is local.
        proto.serverAddress = "127.0.0.1:\(settings.port)"
        proto.providerConfiguration = ["port": settings.port]
        mgr.protocolConfiguration = proto
        mgr.localizedDescription = "TG WS Proxy"
        mgr.isEnabled = true
        manager = mgr
        return mgr
    }

    // MARK: - Start / stop

    func start() {
        state = .starting
        // Persist settings so the extension reads the same values.
        settings.save()
        Task {
            do {
                let mgr = configuredManager()
                try await mgr.saveToPreferences()
                try await mgr.loadFromPreferences() // re-read to get a valid session
                try mgr.connection.startVPNTunnel()
                startPolling()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func stop() {
        state = .stopping
        manager?.connection.stopVPNTunnel()
        pollTask?.cancel()
        pollTask = nil
    }

    func toggle() {
        isRunning || state == .starting ? stop() : start()
    }

    func saveSettings() {
        settings.save()
    }

    func regenerateSecret() {
        settings.secret = ProxySettings.randomSecret()
        settings.save()
    }

    // MARK: - Telegram hand-off

    /// tg:// link, preferring the prefixed secret reported by the running core.
    func telegramURL() -> URL? {
        settings.telegramProxyURL(prefixedSecretOverride: prefixedSecret)
    }

    // MARK: - Status / polling

    private func refreshFromStatus() {
        guard let connection = manager?.connection else { state = .stopped; return }
        switch connection.status {
        case .connected:    state = .running; startPolling()
        case .connecting:   state = .starting
        case .disconnecting: state = .stopping
        case .disconnected, .invalid:
            if case .failed = state { } else { state = .stopped }
            pollTask?.cancel(); pollTask = nil
        case .reasserting:  state = .running
        @unknown default:   state = .stopped
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func pollOnce() async {
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

    private func appendLogs(_ text: String) {
        let incoming = text.split(separator: "\n").map(String.init)
        logLines.append(contentsOf: incoming)
        if logLines.count > 1000 {
            logLines.removeFirst(logLines.count - 1000)
        }
    }

    func clearLogs() {
        logLines.removeAll()
        guard let session = manager?.connection as? NETunnelProviderSession else { return }
        try? session.sendProviderMessage(Data("clearLogs".utf8), responseHandler: nil)
    }
}
