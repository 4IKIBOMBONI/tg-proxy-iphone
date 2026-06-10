import Foundation

/// How the proxy stays alive.
///
/// - `vpn`:   runs inside a Packet Tunnel extension. Best background longevity,
///            but iOS allows only one active VPN tunnel, so it cannot coexist
///            with another system VPN.
/// - `local`: runs the Go core directly inside the app process on loopback.
///            Coexists with any system VPN (the proxy's own traffic even goes
///            through it), but only works while the app is foreground / for a
///            short grace period after backgrounding.
enum BackgroundMode: String, Codable, CaseIterable {
    case vpn
    case local

    var title: String {
        switch self {
        case .vpn:   return "Эмитация VPN-режима (фон)"
        case .local: return "Локальный (совместим с VPN)"
        }
    }

    var subtitle: String {
        switch self {
        case .vpn:   return "Стабильная работа в фоне. Нельзя использовать одновременно с VPN."
        case .local: return "Совместим с любым системным VPN. Работает, пока приложение открыто."
        }
    }
}

/// User-configurable proxy settings, persisted in the shared App Group so both
/// the app (UI) and the tunnel extension (Go core) read the same values.
///
/// Mirrors the configuration surface of the Android fork:
///   - local listen port (default 1443)
///   - 16-byte MTProto secret (hex)
///   - WebSocket connection pool size (2…16)
///   - CloudFlare proxy toggle + optional custom domain
///   - FakeTLS (ee-secret) toggle + SNI domain
///   - optional manual DC→IP overrides
struct ProxySettings: Codable, Equatable {
    var host: String = "127.0.0.1"
    var port: Int = 1443
    /// 32 hex chars = 16 bytes.
    var secret: String = ProxySettings.randomSecret()
    var poolSize: Int = 4
    var cfproxyEnabled: Bool = true
    var cfproxyUserDomain: String = ""
    var fakeTlsEnabled: Bool = false
    var fakeTlsDomain: String = "www.google.com"
    var verboseLogging: Bool = false
    /// Manual DC→IP overrides, e.g. "2:149.154.167.220,4:149.154.167.220".
    /// Empty means "use the core's built-in defaults".
    var dcIps: String = ""
    /// VPN (Packet Tunnel) vs local (in-app) background mode.
    var backgroundMode: BackgroundMode = .vpn
    /// Connect On Demand: when enabled and the proxy is in VPN mode, iOS will
    /// auto-start the tunnel whenever traffic is requested for one of the
    /// configured trigger domains (Telegram by default). Has no effect in
    /// local mode (no NETunnelProviderManager involved).
    var onDemandEnabled: Bool = false
    /// Comma-separated list of DNS suffixes that trigger the tunnel via
    /// NEEvaluateConnectionRule. Each entry matches the suffix of the
    /// hostname being resolved (e.g. "telegram.org" matches "core.telegram.org").
    /// Empty means "use the built-in defaults".
    var onDemandDomains: String = ""

    /// Default trigger domains used when `onDemandDomains` is empty.
    static let defaultOnDemandDomains: [String] = [
        "telegram.org",
        "t.me",
        "telegram-cdn.org",
        "telesco.pe",
        "tg.dev",
        "cdn-telegram.org",
    ]

    /// Returns the effective list of trigger domains for On Demand, normalised
    /// (trimmed, lowercased, deduplicated, no empties).
    var effectiveOnDemandDomains: [String] {
        let raw = onDemandDomains
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let list = raw.isEmpty ? Self.defaultOnDemandDomains : raw
        var seen = Set<String>(), out: [String] = []
        for d in list where seen.insert(d).inserted { out.append(d) }
        return out
    }

    // MARK: Persistence

    private static let storeKey = "proxy.settings.v1"

    static func load() -> ProxySettings {
        guard
            let data = AppGroup.defaults.data(forKey: storeKey),
            let decoded = try? JSONDecoder().decode(ProxySettings.self, from: data)
        else {
            let fresh = ProxySettings()
            fresh.save()
            return fresh
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        AppGroup.defaults.set(data, forKey: Self.storeKey)
    }

    // MARK: Codable (tolerant of missing keys for forward/back compatibility)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ProxySettings()
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? d.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? d.secret
        poolSize = try c.decodeIfPresent(Int.self, forKey: .poolSize) ?? d.poolSize
        cfproxyEnabled = try c.decodeIfPresent(Bool.self, forKey: .cfproxyEnabled) ?? d.cfproxyEnabled
        cfproxyUserDomain = try c.decodeIfPresent(String.self, forKey: .cfproxyUserDomain) ?? d.cfproxyUserDomain
        fakeTlsEnabled = try c.decodeIfPresent(Bool.self, forKey: .fakeTlsEnabled) ?? d.fakeTlsEnabled
        fakeTlsDomain = try c.decodeIfPresent(String.self, forKey: .fakeTlsDomain) ?? d.fakeTlsDomain
        verboseLogging = try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? d.verboseLogging
        dcIps = try c.decodeIfPresent(String.self, forKey: .dcIps) ?? d.dcIps
        backgroundMode = try c.decodeIfPresent(BackgroundMode.self, forKey: .backgroundMode) ?? d.backgroundMode
        onDemandEnabled = try c.decodeIfPresent(Bool.self, forKey: .onDemandEnabled) ?? d.onDemandEnabled
        onDemandDomains = try c.decodeIfPresent(String.self, forKey: .onDemandDomains) ?? d.onDemandDomains
    }

    // MARK: Helpers

    var clampedPoolSize: Int { min(16, max(2, poolSize)) }

    var isSecretValid: Bool {
        secret.count == 32 && secret.allSatisfy { $0.isHexDigit }
    }

    /// Generates a random 16-byte secret rendered as 32 lowercase hex chars.
    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Builds the secret with the protocol prefix the Telegram client expects.
    /// `dd` = secured (random padding), `ee` = FakeTLS (secret + SNI hex).
    /// This mirrors the Go `GetSecretWithPrefix` export and is used when the
    /// core is not running (e.g. to render the tg:// link before starting).
    var prefixedSecret: String {
        if fakeTlsEnabled, !fakeTlsDomain.isEmpty {
            let domHex = Data(fakeTlsDomain.utf8).map { String(format: "%02x", $0) }.joined()
            return "ee" + secret + domHex
        }
        return "dd" + secret
    }

    /// `tg://proxy` deep link that hands the local proxy to a Telegram client.
    func telegramProxyURL(prefixedSecretOverride: String? = nil) -> URL? {
        var comps = URLComponents()
        comps.scheme = "tg"
        comps.host = "proxy"
        comps.queryItems = [
            URLQueryItem(name: "server", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "secret", value: prefixedSecretOverride ?? prefixedSecret),
        ]
        return comps.url
    }
}
