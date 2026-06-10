import AppIntents
import Foundation

/// Public, system-visible action that flips the proxy on or off.
///
/// Where it shows up:
/// - **Siri**: "Эй, Siri, переключи прокси Telegram" (via the phrases in
///   `TgWsProxyShortcuts`).
/// - **Shortcuts.app**: as an action named "Переключить прокси Telegram"
///   under TG WS Proxy.
/// - **Home Screen / Lock Screen**: as a standalone Shortcut tile the user
///   can drop anywhere.
/// - **Control Center**: indirectly — the iOS 18 control widget reuses this
///   same intent under the hood.
///
/// `openAppWhenRun = false` keeps the toggle silent: tapping it from Control
/// Center or asking Siri must not yank the user out of whatever app they are in
/// (typically Telegram itself).
@available(iOS 17.0, *)
struct ToggleProxyIntent: AppIntent {

    static var title: LocalizedStringResource = "Переключить прокси Telegram"
    static var description = IntentDescription(
        "Запускает или останавливает MTProto-прокси TG WS Proxy.",
        categoryName: "Прокси"
    )

    /// Don't bounce the user into the app — the whole point of these system
    /// surfaces is that they work without context switches.
    static var openAppWhenRun: Bool = false
    /// Show a status update in the Shortcuts / Siri response.
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let nowRunning: Bool
        do {
            // App Intents invoked from Siri / Shortcuts / Lock Screen run in
            // a background extension-style process that can't surface the
            // "Allow VPN configuration" dialog. We refuse to silently fail by
            // passing allowInstall: false; if the user has never started the
            // proxy from the app, ProxyToggle.start throws .notInstalled with
            // a clear message.
            nowRunning = try await ProxyToggle.toggle(allowInstall: false)
        } catch {
            // Surface the underlying error in the Siri / Shortcuts result so
            // the user (or the automation) can react. We deliberately don't
            // throw — a thrown error here would make Shortcuts say "An error
            // occurred" with no detail.
            return .result(dialog: IntentDialog("Не удалось переключить прокси: \(error.localizedDescription)"))
        }
        let phrase: LocalizedStringResource = nowRunning
            ? "Прокси Telegram запущен"
            : "Прокси Telegram остановлен"
        return .result(dialog: IntentDialog(phrase))
    }
}

/// Explicit start — useful in automations like "when I arrive home, turn on
/// the proxy".
@available(iOS 17.0, *)
struct StartProxyIntent: AppIntent {
    static var title: LocalizedStringResource = "Запустить прокси Telegram"
    static var description = IntentDescription("Запускает MTProto-прокси TG WS Proxy.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try await ProxyToggle.start(allowInstall: false)
            return .result(dialog: "Прокси Telegram запущен")
        } catch {
            return .result(dialog: IntentDialog("Не удалось запустить прокси: \(error.localizedDescription)"))
        }
    }
}

/// Explicit stop — paired with `StartProxyIntent` for automations.
@available(iOS 17.0, *)
struct StopProxyIntent: AppIntent {
    static var title: LocalizedStringResource = "Остановить прокси Telegram"
    static var description = IntentDescription("Останавливает MTProto-прокси TG WS Proxy.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try await ProxyToggle.stop()
            return .result(dialog: "Прокси Telegram остановлен")
        } catch {
            return .result(dialog: IntentDialog("Не удалось остановить прокси: \(error.localizedDescription)"))
        }
    }
}

/// Registers Siri voice shortcuts and the default Shortcuts.app entries so the
/// user doesn't have to set anything up manually.
@available(iOS 17.0, *)
struct TgWsProxyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleProxyIntent(),
            phrases: [
                "Переключи прокси в \(.applicationName)",
                "Toggle proxy in \(.applicationName)",
                "Включи прокси Telegram в \(.applicationName)",
                "Выключи прокси Telegram в \(.applicationName)",
            ],
            shortTitle: "Прокси",
            systemImageName: "bolt.horizontal.circle"
        )
        AppShortcut(
            intent: StartProxyIntent(),
            phrases: [
                "Запусти прокси в \(.applicationName)",
                "Start proxy in \(.applicationName)",
            ],
            shortTitle: "Запустить",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StopProxyIntent(),
            phrases: [
                "Останови прокси в \(.applicationName)",
                "Stop proxy in \(.applicationName)",
            ],
            shortTitle: "Остановить",
            systemImageName: "stop.circle"
        )
    }
}
