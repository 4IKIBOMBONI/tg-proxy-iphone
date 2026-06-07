import Foundation

/// Thin Swift wrapper around the Go core's C API. Lives in (and is only ever
/// called from) the Packet Tunnel extension process, where the proxy actually
/// runs. All `char*` returns from the core are owned by us and freed via
/// `FreeString`.
enum ProxyCore {

    enum StartError: Error, CustomStringConvertible {
        case alreadyRunning      // -1
        case badDCConfig         // -2
        case listenFailed        // -3
        case unknown(Int32)

        var description: String {
            switch self {
            case .alreadyRunning: return "прокси уже запущен"
            case .badDCConfig:    return "неверная конфигурация DC IP"
            case .listenFailed:   return "не удалось открыть локальный порт"
            case .unknown(let c): return "неизвестная ошибка ядра (\(c))"
            }
        }
    }

    /// Applies all tunables and starts the proxy listener. Returns the
    /// prefixed secret (dd…/ee…) the Telegram client must use.
    @discardableResult
    static func start(with settings: ProxySettings) throws -> String {
        // CloudFlare domain cache lives in the shared container so it survives
        // extension restarts.
        if let cacheDir = AppGroup.containerURL?.path {
            cacheDir.withCStringCopy { SetCfProxyCacheDir($0) }
        }

        SetPoolSize(Int32(settings.clampedPoolSize))
        settings.cfproxyUserDomain.withCStringCopy {
            SetCfProxyConfig(settings.cfproxyEnabled ? 1 : 0, 0, $0)
        }
        settings.fakeTlsDomain.withCStringCopy {
            SetFakeTls(settings.fakeTlsEnabled ? 1 : 0, $0)
        }

        let rc: Int32 = settings.host.withCStringCopy { host in
            settings.dcIps.withCStringCopy { dcIps in
                settings.secret.withCStringCopy { secret in
                    StartProxy(host, Int32(settings.port), dcIps, secret,
                               settings.verboseLogging ? 1 : 0)
                }
            }
        }

        switch rc {
        case 0:   return prefixedSecret()
        case -1:  throw StartError.alreadyRunning
        case -2:  throw StartError.badDCConfig
        case -3:  throw StartError.listenFailed
        default:  throw StartError.unknown(rc)
        }
    }

    static func stop() {
        _ = StopProxy()
    }

    static func prefixedSecret() -> String {
        consumeCString(GetSecretWithPrefix())
    }

    static func statsRu() -> String {
        consumeCString(GetStatsRu())
    }

    static func stats() -> String {
        consumeCString(GetStats())
    }

    /// Drains and returns the buffered log lines (joined by "\n").
    static func drainLogs() -> String {
        consumeCString(GetLogs())
    }

    static func clearLogs() {
        ClearLogs()
    }

    // MARK: - C string helpers

    private static func consumeCString(_ ptr: UnsafeMutablePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        defer { FreeString(ptr) }
        return String(cString: ptr)
    }
}

private extension String {
    /// Calls `body` with a mutable, NUL-terminated copy of this string. The Go
    /// core copies the bytes (C.GoString) so the buffer only needs to live for
    /// the duration of the call.
    func withCStringCopy<R>(_ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
        var bytes = Array(utf8CString)
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
