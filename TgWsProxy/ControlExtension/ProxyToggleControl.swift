import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

/// Kind identifier for the toggle control. Re-exported from `AppGroup` so
/// the widget code can keep using `ProxyControl.toggleKind` without importing
/// the shared module's symbol directly.
@available(iOS 18.0, *)
enum ProxyControl {
    static let toggleKind = AppGroup.controlToggleKind
}

/// Top-level entry for the Control Center widget bundle. Holds every control
/// widget shipped by this extension; today there is exactly one toggle, but
/// keeping a bundle makes it trivial to add more (per-domain triggers, On
/// Demand toggle, etc.) without touching `project.yml` again.
@main
@available(iOS 18.0, *)
struct TgWsProxyControlBundle: WidgetBundle {
    var body: some Widget {
        ProxyToggleControl()
    }
}

/// Control Center toggle that flips the proxy on/off, mirrored on the Lock
/// Screen and addable to the Home Screen via "Edit Home Screen → Add Control".
///
/// Anatomy:
/// - `ControlWidgetToggle` is the iOS 18 control type that owns a binary state
///   and an action to flip it.
/// - The current value comes from `ProxyStatusProvider`, which queries the
///   real `NEVPNStatus` so the tile reflects what iOS thinks of the tunnel,
///   not just our last toggle action. If a competing VPN turns ours off, or
///   the user disables it from Settings → VPN, the next refresh shows the
///   correct state.
/// - The flip action is a `SetValueIntent` (`SetProxyEnabledIntent`) so iOS
///   can call it without launching the app and without needing a perform UI.
@available(iOS 18.0, *)
struct ProxyToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: ProxyControl.toggleKind,
            provider: ProxyStatusProvider()
        ) { state in
            ControlWidgetToggle(
                state.title,
                isOn: state.isOn,
                action: SetProxyEnabledIntent()
            ) { isOn in
                Label(state.label, systemImage: state.symbol)
            }
        }
        .displayName("TG WS Proxy")
        .description("Запуск и остановка MTProto-прокси из Пункта управления.")
    }
}

/// Snapshot of the proxy state used to render the control. Bundles the boolean
/// (for the toggle) and the textual hints so the tile can show a richer status
/// — "Подключение…", "Отключение…", "Не установлен" — instead of a flat on/off.
@available(iOS 18.0, *)
struct ProxyControlState: Equatable {
    var isOn: Bool
    var title: String
    var label: String
    var symbol: String

    static let off = ProxyControlState(
        isOn: false,
        title: "Прокси Telegram",
        label: "Прокси выключен",
        symbol: "bolt.horizontal.circle"
    )

    static let on = ProxyControlState(
        isOn: true,
        title: "Прокси Telegram",
        label: "Прокси работает",
        symbol: "bolt.horizontal.circle.fill"
    )

    static let connecting = ProxyControlState(
        isOn: true, // keep the toggle visually "on" while we negotiate
        title: "Прокси Telegram",
        label: "Подключение…",
        symbol: "bolt.horizontal.circle"
    )

    static let disconnecting = ProxyControlState(
        isOn: false,
        title: "Прокси Telegram",
        label: "Отключение…",
        symbol: "bolt.horizontal.circle"
    )

    static let notInstalled = ProxyControlState(
        isOn: false,
        title: "Прокси Telegram",
        label: "Откройте приложение",
        symbol: "exclamationmark.bubble"
    )
}

/// Provides the current state for the control. iOS calls this whenever it
/// needs to redraw the tile — after our `SetValueIntent` returns, and after
/// the main app calls `ControlCenter.shared.reloadControls(ofKind:)` in
/// response to `NEVPNStatusDidChange`.
@available(iOS 18.0, *)
struct ProxyStatusProvider: ControlValueProvider {
    var previewValue: ProxyControlState { .off }

    func currentValue() async throws -> ProxyControlState {
        guard let mgr = await ProxyToggle.existingManager() else {
            return .notInstalled
        }
        switch mgr.connection.status {
        case .connected:                    return .on
        case .connecting, .reasserting:     return .connecting
        case .disconnecting:                return .disconnecting
        case .disconnected, .invalid:       return .off
        @unknown default:                   return .off
        }
    }
}

/// The `SetValueIntent` invoked by the toggle. iOS passes the desired target
/// state in `value`; we translate that to start/stop calls on the shared
/// `ProxyToggle`.
///
/// `isDiscoverable = false` keeps it out of the Shortcuts app — users should
/// pick the higher-level `ToggleProxyIntent` there instead.
@available(iOS 18.0, *)
struct SetProxyEnabledIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Включить/выключить прокси"
    static var description = IntentDescription("Управляет состоянием прокси TG WS Proxy.")
    static var isDiscoverable: Bool = false

    @Parameter(title: "Включён")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    func perform() async throws -> some IntentResult {
        // We run inside the Control Center extension process, which is not
        // entitled to add a *new* VPN profile (that would require the user to
        // confirm the system dialog, which an extension can't show). So we
        // only refresh and start an already-installed profile here; if there
        // is none, throw so the toggle UI doesn't get stuck "on" without an
        // actual tunnel underneath.
        if value {
            try await ProxyToggle.start(allowInstall: false)
        } else {
            try await ProxyToggle.stop()
        }
        // Force iOS to repaint the tile right now using the freshly-updated
        // status, otherwise it would keep our optimistic value until the next
        // system-triggered refresh.
        ControlCenter.shared.reloadControls(ofKind: ProxyControl.toggleKind)
        return .result()
    }
}
