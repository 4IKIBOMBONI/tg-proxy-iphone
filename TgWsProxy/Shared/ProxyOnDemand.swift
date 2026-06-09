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
/// We use `NEEvaluateConnectionRule` rather than `NEOnDemandRuleConnect` so we
/// can scope the trigger to specific domains; a blanket Connect rule would
/// also work but would keep the tunnel up for *all* network access.
public enum ProxyOnDemand {

    /// Returns an array of `NEOnDemandRule` to assign to a
    /// `NETunnelProviderManager.onDemandRules`. Empty if the feature is
    /// disabled or there are no domains to match.
    public static func buildRules(from settings: ProxySettings) -> [NEOnDemandRule] {
        guard settings.onDemandEnabled else { return [] }
        let domains = settings.effectiveOnDemandDomains
        guard !domains.isEmpty else { return [] }

        // Primary rule: when any traffic is requested for one of the Telegram
        // domains, evaluate a synthetic "connection rule" that always says
        // "connect to my probe domain". Since the probe domain matches one of
        // the trigger domains, iOS interprets the outcome as "bring the VPN
        // up first, then complete the lookup".
        let connect = NEEvaluateConnectionRule(
            matchDomains: domains,
            andAction: .connectIfNeeded
        )
        // Probe URL is what iOS uses to verify the action; we point it at a
        // benign endpoint on telegram.org. The request never actually leaves
        // the device — iOS only inspects the URL to decide whether the rule
        // matches the current resolution.
        connect.probeURL = URL(string: "https://telegram.org/")

        let evaluate = NEOnDemandRuleEvaluateConnection()
        evaluate.connectionRules = [connect]
        // Apply on every interface type — Telegram is used over both Wi-Fi
        // and cellular.
        evaluate.interfaceTypeMatch = .any

        // Fallback rule: for anything that isn't a Telegram domain, do
        // nothing — don't bring the tunnel up, don't tear it down.
        // (Disconnect would race with the user's manual start.)
        let ignore = NEOnDemandRuleIgnore()
        ignore.interfaceTypeMatch = .any

        return [evaluate, ignore]
    }
}
