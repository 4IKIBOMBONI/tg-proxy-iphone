<div align="center">

# TG WS Proxy iPhone

**Локальный MTProto-прокси для Telegram на iOS** — порт [tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (Flowseal) и его [Android-форка](https://github.com/amurcanov/tg-ws-proxy-android) (amurcanov) на iPhone.

Go-ядро прокси переиспользуется без изменений логики, UI написан на SwiftUI, фоновая работа реализована через NetworkExtension (Packet Tunnel).

</div>

---

## Что это

Приложение поднимает локальный **MTProto-прокси** на `127.0.0.1:1443` и перенаправляет трафик Telegram через защищённые WebSocket-соединения — напрямую к датацентрам Telegram или через CloudFlare CDN. Помогает частично обходить проблемы с доступом и в ряде сценариев ускоряет работу мессенджера.

```text
Telegram iOS → Локальный MTProto (127.0.0.1:1443) → TG WS Proxy → WSS (CloudFlare / напрямую) → Telegram DC
```

## Возможности

- **Go-ядро 1:1 с Android-форком** — тот же `tg-ws-proxy.go` (пул WS-соединений, DoH, CloudFlare-домены с авто-обновлением, FakeTLS, fallback-сценарии).
- **Фоновая работа через Packet Tunnel** — прокси живёт в сетевом расширении, поэтому не выгружается, когда приложение свёрнуто.
- **SwiftUI-интерфейс** — старт/стоп, статистика в реальном времени, лог-вьюер, настройки.
- **Кнопка «Применить в Telegram»** — передаёт прокси в Telegram/AyuGram/NekoGram и др. через `tg://proxy`.
- **Настройки** — порт, секрет (с генерацией), размер пула (2–16), CloudFlare вкл/выкл + свой домен, FakeTLS + SNI, ручные DC→IP, подробные логи.

## Архитектура

```
tg-proxy-iphone/
├── core/                         # Go-ядро прокси + сборка под iOS
│   ├── tg-ws-proxy.go            # ядро из Android-форка (1 строка-патч для iOS-логов)
│   ├── ios_bridge.go             # кольцевой буфер логов + экспорт GetLogs/GetStatsRu
│   ├── go.mod
│   └── build-xcframework.sh      # сборка TgWsProxyCore.xcframework (c-archive)
└── TgWsProxy/                    # Xcode-проект (генерируется из project.yml)
    ├── project.yml               # XcodeGen-спека (2 таргета: app + tunnel)
    ├── App/                      # SwiftUI-приложение
    │   ├── TgWsProxyApp.swift
    │   ├── ContentView.swift
    │   ├── ProxyController.swift  # управление NETunnelProviderManager
    │   └── Views/                 # Status / Log / Settings / Info
    ├── Tunnel/                    # NEPacketTunnelProvider
    │   └── PacketTunnelProvider.swift
    └── Shared/                    # общий код app+extension
        ├── AppGroup.swift
        ├── ProxySettings.swift
        ├── ProxyCore.swift        # Swift-обёртка над C-API ядра
        └── TgWsProxyCore-Bridging-Header.h
```

### Как ядро попадает в Swift

Go-ядро уже экспортирует **чистый C-API** через `//export` (`StartProxy`, `StopProxy`, `GetStats`, `GetSecretWithPrefix`, …). Поэтому gomobile bind не нужен — мы собираем `go build -buildmode=c-archive` для каждого среза (device arm64, simulator arm64/x86_64) и упаковываем статические архивы с заголовком в `TgWsProxyCore.xcframework`. Swift вызывает функции напрямую через bridging header.

### Почему Packet Tunnel

На iOS обычное приложение засыпает в фоне, поэтому простой loopback-сервер (как foreground-сервис на Android) был бы убит. Прокси запускается внутри `NEPacketTunnelProvider`: система держит этот процесс живым, пока активно VPN-«соединение». Туннель намеренно **не перехватывает трафик** (нет included routes) — его единственная задача держать прокси в памяти. Telegram, настроенный на `tg://proxy`, подключается к loopback напрямую; исходящие WS-соединения прокси идут обычным сетевым путём.

## Требования

- **macOS** с **Xcode 15+**.
- **Go 1.21+** (модуль таргетит 1.26), `CGO_ENABLED=1`.
- [**XcodeGen**](https://github.com/yonyz/XcodeGen) (`brew install xcodegen`).
- **Платный аккаунт Apple Developer** — нужен entitlement **Network Extensions (Packet Tunnel)** и **App Groups**. На бесплатном аккаунте Packet Tunnel недоступен.

## Сборка

```bash
# 1. Собрать Go-ядро в xcframework
cd core
./build-xcframework.sh          # → core/build/TgWsProxyCore.xcframework

# 2. Сгенерировать Xcode-проект
cd ../TgWsProxy
xcodegen generate               # → TgWsProxy.xcodeproj

# 3. Открыть и собрать
open TgWsProxy.xcodeproj
```

В Xcode перед запуском:

1. Выбрать свою команду разработчика (**Signing & Capabilities → Team**) для обоих таргетов (`TgWsProxy` и `Tunnel`).
2. Убедиться, что в обоих таргетах есть capabilities **App Groups** (`group.com.tgwsproxy.shared`) и **Network Extensions → Packet Tunnel**.
3. При необходимости поменять bundle id и App Group в `project.yml` и `Shared/AppGroup.swift` (значения должны совпадать).

> Идентификаторы по умолчанию: app `com.tgwsproxy.app`, расширение `com.tgwsproxy.app.tunnel`, App Group `group.com.tgwsproxy.shared`.

## Использование

1. Запустить приложение, нажать кнопку питания — iOS попросит разрешить добавление VPN-конфигурации (это Packet Tunnel).
2. Дождаться статуса «Прокси работает».
3. Нажать **«Применить в Telegram»** — откроется Telegram с готовыми настройками прокси, подтвердить подключение.
4. Логи и статистику можно смотреть на соответствующих вкладках.

## Ограничения iOS

- Требуется VPN-профиль (Packet Tunnel) — обойти системные ограничения фона иначе нельзя.
- Apple может «усыплять» расширение при экстремальной экономии заряда; при проблемах перезапустите прокси.
- Нужен платный Apple Developer аккаунт (см. «Требования»).

## Обновление ядра из апстрима

`core/tg-ws-proxy.go` — копия файла из Android-форка с **единственным** изменением: вызов `iosCaptureLog(p)` в `androidLogWriter.Write` (зеркалирование логов в буфер для UI). Чтобы подтянуть свежую версию ядра, перенесите этот один вызов в новый файл и пересоберите xcframework.

## Лицензия

Распространяется под **GPLv3** (как и Android-форк). Оригинальный код `tg-ws-proxy` от [Flowseal](https://github.com/Flowseal) доступен под **MIT**.

Атрибуция:
- Ядро: [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) (MIT)
- Go-порт ядра: [amurcanov/tg-ws-proxy-android](https://github.com/amurcanov/tg-ws-proxy-android) (GPLv3)
