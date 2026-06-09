import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

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
/// - The current value comes from `ProxyStatusProvider`, which queries
///   `NETunnelProviderManager` synchronously enough for Control Center's needs.
/// - The flip action is a `SetValueIntent` (`SetProxyEnabledIntent`) so iOS
///   can call it without launching the app and without needing a perform UI.
@available(iOS 18.0, *)
struct ProxyToggleControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.tgwsproxy.controls.toggle",
            provider: ProxyStatusProvider()
        ) { value in
            ControlWidgetToggle(
                "Прокси Telegram",
                isOn: value,
                action: SetProxyEnabledIntent()
            ) { isOn in
                Label(isOn ? "Прокси работает" : "Прокси выключен",
                      systemImage: isOn ? "bolt.horizontal.circle.fill"
                                        : "bolt.horizontal.circle")
            }
        }
        .displayName("TG WS Proxy")
        .description("Запуск и остановка MTProto-прокси из Пункта управления.")
    }
}

/// Provides the current on/off value for the control. iOS calls this whenever
/// it needs to redraw the tile, including right after our `SetValueIntent`
/// returns.
@available(iOS 18.0, *)
struct ProxyStatusProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        await ProxyToggle.isRunning()
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
        if value {
            try await ProxyToggle.start()
        } else {
            try await ProxyToggle.stop()
        }
        return .result()
    }
}
