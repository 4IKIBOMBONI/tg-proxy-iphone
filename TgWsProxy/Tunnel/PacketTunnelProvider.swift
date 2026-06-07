import NetworkExtension
import os

/// Packet Tunnel provider that hosts the Go MTProto proxy.
///
/// iOS suspends regular apps in the background, so a plain loopback listener
/// (like the Android foreground service) would die. Instead we run inside a
/// NEPacketTunnelProvider: the system keeps this process alive while the VPN
/// "connection" is active. We deliberately set up a tunnel that captures **no**
/// traffic (no included routes) — its only job is to keep us resident so the
/// loopback MTProto proxy on 127.0.0.1:<port> stays reachable. Telegram, once
/// pointed at that proxy via tg://proxy, connects to it directly over loopback;
/// the proxy's own outbound WebSocket connections to Telegram DCs / CloudFlare
/// use the normal network path.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.tgwsproxy.app.tunnel", category: "tunnel")
    private var reportTimer: DispatchSourceTimer?
    private var settings = ProxySettings()

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?,
                             completionHandler: @escaping (Error?) -> Void) {
        // Settings come from the shared App Group (written by the app before
        // it asked the manager to connect). Fall back to provider config.
        settings = ProxySettings.load()
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let conf = proto.providerConfiguration,
           let port = conf["port"] as? Int {
            settings.port = port
        }

        log.info("startTunnel: starting proxy on \(self.settings.host):\(self.settings.port)")

        do {
            let prefixed = try ProxyCore.start(with: settings)
            AppGroup.defaults.set(prefixed, forKey: "proxy.prefixedSecret")
            AppGroup.defaults.set(true, forKey: "proxy.running")
        } catch {
            log.error("proxy start failed: \(String(describing: error))")
            AppGroup.defaults.set(false, forKey: "proxy.running")
            completionHandler(error)
            return
        }

        applyTunnelSettings { [weak self] err in
            guard let self else { return }
            if let err {
                self.log.error("setTunnelNetworkSettings failed: \(err.localizedDescription)")
                ProxyCore.stop()
                completionHandler(err)
                return
            }
            self.startReporting()
            self.readPacketsLoop()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason,
                            completionHandler: @escaping () -> Void) {
        log.info("stopTunnel: reason=\(reason.rawValue)")
        reportTimer?.cancel()
        reportTimer = nil
        ProxyCore.stop()
        AppGroup.defaults.set(false, forKey: "proxy.running")
        completionHandler()
    }

    /// IPC channel from the app. Returns a JSON snapshot of status/logs/stats.
    override func handleAppMessage(_ messageData: Data,
                                  completionHandler: ((Data?) -> Void)?) {
        let command = String(data: messageData, encoding: .utf8) ?? ""
        switch command {
        case "stop":
            ProxyCore.stop()
            completionHandler?(Data("ok".utf8))
        case "clearLogs":
            ProxyCore.clearLogs()
            completionHandler?(Data("ok".utf8))
        default: // "status"
            let snapshot: [String: Any] = [
                "running": true,
                "stats": ProxyCore.statsRu(),
                "logs": ProxyCore.drainLogs(),
                "prefixedSecret": ProxyCore.prefixedSecret(),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: snapshot)) ?? Data()
            completionHandler?(data)
        }
    }

    // MARK: - Tunnel config (no traffic capture)

    private func applyTunnelSettings(_ completion: @escaping (Error?) -> Void) {
        let tunnel = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"])
        // No included routes => the system routes no traffic into this tunnel.
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = [NEIPv4Route.default()]
        tunnel.ipv4Settings = ipv4

        // Resolve DNS normally; we are not a DNS proxy.
        tunnel.mtu = 1500

        setTunnelNetworkSettings(tunnel, completionHandler: completion)
    }

    /// We capture no traffic, but draining the packet flow keeps the tunnel
    /// healthy and avoids backpressure warnings from the system.
    private func readPacketsLoop() {
        packetFlow.readPacketObjects { [weak self] _ in
            self?.readPacketsLoop()
        }
    }

    // MARK: - Periodic reporting to the App Group

    private func startReporting() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            AppGroup.defaults.set(ProxyCore.statsRu(), forKey: "proxy.stats")
            if let url = AppGroup.logFileURL {
                let logs = ProxyCore.drainLogs()
                if !logs.isEmpty {
                    self.appendLogs(logs, to: url)
                }
            }
        }
        timer.resume()
        reportTimer = timer
    }

    private func appendLogs(_ text: String, to url: URL) {
        let chunk = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(chunk)
            // Trim the file if it grows past ~256 KB.
            if handle.offsetInFile > 256 * 1024 {
                trimLogFile(url)
            }
        } else {
            try? chunk.write(to: url)
        }
    }

    private func trimLogFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(128 * 1024)
        try? tail.write(to: url)
    }
}
