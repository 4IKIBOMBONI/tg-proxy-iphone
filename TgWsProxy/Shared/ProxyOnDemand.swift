import Foundation
import NetworkExtension

/// Builds Connect On Demand rules for the proxy tunnel.
///
/// iOS On Demand cannot trigger on "app X launched"; the system only lets us
/// react to network conditions (Wi-Fi SSID, cellular, reachable host) and DNS
/// lookups for specific domains. The closest thing to "auto-start when the user
/// opens Telegram" is therefore a DNS-domain rule: whenever the system tries to
/// resolve a Telegram-owned domain, iOS spins up our Packet Tunnel first, and
/// only then lets the resolution proceed.
///
/// The Telegram iOS client resolves a handful of well-known domains on launch
/// (`*.telegram.org`, `t.me`, `telegram-cdn.org`, `telesco.pe`, …). Matching on
/// any of these is enough in practice to make the proxy come up before the
/// first DC connection is attempted.
///
/// We use a two-rule chain:
///   1. `NEOnDemandRuleConnect` with `dnsSearchDomainMatch` set to the
///      Telegram domains — this fires when iOS resolves any hostname under
///      one of those suffixes. Connect rules trigger reliably on iOS 17+,
///      `NEEvaluateConnectionRule` does not when the host isn't probed.
///   2. `NEOnDemandRuleIgnore` as the catch-all so we don't bring the tunnel
///      up for unrelated traffic.
enum ProxyOnDemand {

    /// Returns an array of `NEOnDemandRule` to assign to a
    /// `NETunnelProviderManager.onDemandRules`. Empty if the feature is
    /// disabled or there are no domains to match.
    static func buildRules(from settings: ProxySettings) -> [NEOnDemandRule] {
        guard settings.onDemandEnabled else { return [] }
        let domains = settings.effectiveOnDemandDomains
        guard !domains.isEmpty else { return [] }

        // Primary rule: connect whenever the system resolves a hostname under
        // any of the Telegram domains. `dnsSearchDomainMatch` matches by
        // suffix, so "telegram.org" catches "api.telegram.org",
        // "core.telegram.org" and friends.
        let connect = NEOnDemandRuleConnect()
        connect.interfaceTypeMatch = .any
        connect.dnsSearchDomainMatch = domains

        // Belt-and-braces: also wire an EvaluateConnection rule pointing at
        // those same domains. On some iOS minor versions one fires more
        // reliably than the other; having both costs nothing and OR's them.
        let eval = NEEvaluateConnectionRule(
            matchDomains: domains,
            andAction: .connectIfNeeded
        )
        eval.probeURL = URL(string: "https://core.telegram.org/")
        let evaluate = NEOnDemandRuleEvaluateConnection()
        evaluate.connectionRules = [eval]
        evaluate.interfaceTypeMatch = .any

        // Fallback rule: for anything that isn't a Telegram domain, do
        // nothing — don't bring the tunnel up, don't tear it down.
        let ignore = NEOnDemandRuleIgnore()
        ignore.interfaceTypeMatch = .any

        return [connect, evaluate, ignore]
    }
}
