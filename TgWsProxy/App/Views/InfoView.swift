import SwiftUI

struct InfoView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Как это работает") {
                    infoText("""
                    Telegram iOS → Локальный MTProto (127.0.0.1:порт) → TG WS Proxy → \
                    WSS (через CloudFlare или напрямую) → Telegram DC

                    Приложение поднимает локальный MTProto-прокси внутри сетевого \
                    расширения (Packet Tunnel). Расширение держит фоновый процесс живым, \
                    поэтому прокси остаётся доступным, даже когда приложение свёрнуто.
                    """)
                }

                Section("Подключение Telegram") {
                    step(1, "Запустите прокси на главном экране.")
                    step(2, "Нажмите «Применить в Telegram» — откроется клиент с готовыми настройками прокси.")
                    step(3, "Подтвердите подключение прокси в Telegram.")
                    infoText("Поддерживаются Telegram, AyuGram, Plus Messenger, NekoGram и другие совместимые клиенты, понимающие ссылки tg://proxy.")
                }

                Section("Особенности iOS") {
                    infoText("""
                    • Для фоновой работы используется Packet Tunnel (VPN-профиль). \
                    При первом запуске iOS попросит разрешить добавление VPN-конфигурации.
                    • Сам туннель не перехватывает трафик — он нужен только чтобы система \
                    не выгружала прокси из памяти.
                    • Для сборки нужен платный аккаунт Apple Developer с возможностью \
                    Network Extensions (Packet Tunnel) и App Groups.
                    """)
                }

                Section("CloudFlare и FakeTLS") {
                    infoText("""
                    CloudFlare-домены используются как резервный путь, если прямое \
                    WebSocket-соединение к датацентру недоступно. Список доменов \
                    обновляется автоматически и кэшируется.

                    FakeTLS (ee-secret) маскирует трафик под TLS-рукопожатие, что \
                    помогает против DPI. Включается в настройках.
                    """)
                }

                Section("Лицензия") {
                    infoText("""
                    Ядро прокси основано на tg-ws-proxy от Flowseal (MIT) и его \
                    Android-форке от amurcanov (GPLv3). Этот iOS-порт распространяется \
                    под GPLv3.
                    """)
                }
            }
            .navigationTitle("Информация")
        }
    }

    private func infoText(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.footnote.bold())
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.cyan.opacity(0.3)))
            Text(text).font(.footnote)
        }
    }
}
