import Foundation

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
