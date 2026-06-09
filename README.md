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
- **Control Center / Siri / Shortcuts (iOS 17–18+)** — старт/стоп прокси одним тапом из Пункта управления, голосом или из автоматизаций, без открытия приложения.
- **Connect On Demand** — iOS сам поднимает VPN-прокси, как только Telegram пытается обратиться к сети.
- **Настройки** — порт, секрет (с генерацией), размер пула (2–16), CloudFlare вкл/выкл + свой домен, FakeTLS + SNI, ручные DC→IP, On Demand-домены, подробные логи.

## Архитектура

```
tg-proxy-iphone/
├── core/                         # Go-ядро прокси + сборка под iOS
│   ├── tg-ws-proxy.go            # ядро из Android-форка (1 строка-патч для iOS-логов)
│   ├── ios_bridge.go             # кольцевой буфер логов + экспорт GetLogs/GetStatsRu
│   ├── go.mod
│   └── build-xcframework.sh      # сборка TgWsProxyCore.xcframework (c-archive)
└── TgWsProxy/                    # Xcode-проект (генерируется из project.yml)
    ├── project.yml               # XcodeGen-спека (3 таргета: app + tunnel + control)
    ├── App/                      # SwiftUI-приложение
    │   ├── TgWsProxyApp.swift
    │   ├── ContentView.swift
    │   ├── ProxyController.swift  # управление NETunnelProviderManager
    │   ├── AppIntents/             # ToggleProxyIntent + AppShortcutsProvider (Siri)
    │   └── Views/                 # Status / Log / Settings / Info
    ├── Tunnel/                    # NEPacketTunnelProvider
    │   └── PacketTunnelProvider.swift
    ├── ControlExtension/          # iOS 18 Control Center widget (toggle)
    │   └── ProxyToggleControl.swift
    └── Shared/                    # общий код app+extensions
        ├── AppGroup.swift
        ├── ProxySettings.swift
        ├── ProxyToggle.swift       # headless start/stop, без UI/Go
        ├── ProxyOnDemand.swift     # NEOnDemandRule по доменам Telegram
        ├── ProxyCore.swift         # Swift-обёртка над C-API ядра
        └── TgWsProxyCore-Bridging-Header.h
```

### Как ядро попадает в Swift

Go-ядро уже экспортирует **чистый C-API** через `//export` (`StartProxy`, `StopProxy`, `GetStats`, `GetSecretWithPrefix`, …). Поэтому gomobile bind не нужен — мы собираем `go build -buildmode=c-archive` для каждого среза (device arm64, simulator arm64/x86_64) и упаковываем статические архивы с заголовком в `TgWsProxyCore.xcframework`. Swift вызывает функции напрямую через bridging header.

### Почему Packet Tunnel

На iOS обычное приложение засыпает в фоне, поэтому простой loopback-сервер (как foreground-сервис на Android) был бы убит. Прокси запускается внутри `NEPacketTunnelProvider`: система держит этот процесс живым, пока активно VPN-«соединение». Туннель намеренно **не перехватывает трафик** (нет included routes) — его единственная задача держать прокси в памяти. Telegram, настроенный на `tg://proxy`, подключается к loopback напрямую; исходящие WS-соединения прокси идут обычным сетевым путём.

### Режимы работы (совместимость с VPN)

iOS разрешает **только один активный VPN-туннель одновременно**. Packet Tunnel формально считается VPN, поэтому его нельзя включить одновременно с другим системным VPN. Для таких случаев в настройках есть выбор режима:

| Режим | Где работает ядро | Фон | Совместимость с другим VPN |
|-------|-------------------|-----|----------------------------|
| **VPN-режим** | в Packet Tunnel расширении | стабильно в фоне | ❌ нельзя одновременно с другим VPN |
| **Локальный** | прямо в процессе приложения (loopback) | пока приложение открыто + короткий грейс-период | ✅ совместим с любым VPN |

В локальном режиме VPN-профиль не создаётся, поэтому ваш системный VPN работает свободно — и трафик прокси даже идёт через него. Чтобы прокси не умирал мгновенно при переходе в Telegram, приложение берёт короткий `UIApplication` background task (хватает на подтверждение прокси в Telegram). Постоянная фоновая работа в локальном режиме невозможна из-за ограничений iOS — для неё используйте VPN-режим.

## Требования

- **macOS** с **Xcode 16+** (Control Widget = iOS 18 SDK).
- **iOS 17.0+** на устройстве (App Intents / Siri Shortcuts). Кнопка в Пункте управления требует **iOS 18+**.
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

### Bundle id и команда разработчика

Bundle id обоих таргетов выводятся из **одной переменной** `APP_ID_BASE` в `project.yml`:
- приложение → `$(APP_ID_BASE)`
- расширение → `$(APP_ID_BASE).tunnel`

Это гарантирует правило iOS «id расширения должен начинаться с id приложения». Чтобы поставить свой id, поменяйте **только** `APP_ID_BASE` в `project.yml` и пересоберите проект (`xcodegen generate`). Id туннеля в Swift вычисляется из bundle id приложения в рантайме, так что синхронизировать руками ничего не нужно.

> ⚠️ Не меняйте bundle id прямо в Xcode — `xcodegen generate` перезапишет проект. Правьте `project.yml`.

Команду разработчика можно задать двумя способами:
- в `project.yml`: `DEVELOPMENT_TEAM: ВАШ_TEAM_ID`, затем `xcodegen generate`, **или**
- в Xcode: **Signing & Capabilities → Team** для обоих таргетов (`TgWsProxy` и `Tunnel`).

В Xcode также убедитесь, что у обоих таргетов есть capabilities **App Groups** (`group.com.tgwsproxy.shared`) и **Network Extensions → Packet Tunnel**. App Group должен быть зарегистрирован в вашем аккаунте; при необходимости поменяйте его в `Shared/AppGroup.swift` и в обоих `*.entitlements`.

> Идентификаторы по умолчанию: app `com.tgwsproxy.app`, расширение `com.tgwsproxy.app.tunnel`, App Group `group.com.tgwsproxy.shared`.

## Использование

1. Запустить приложение, нажать кнопку питания — iOS попросит разрешить добавление VPN-конфигурации (это Packet Tunnel).
2. Дождаться статуса «Прокси работает».
3. Нажать **«Применить в Telegram»** — откроется Telegram с готовыми настройками прокси, подтвердить подключение.
4. Логи и статистику можно смотреть на соответствующих вкладках.

### Запуск без открытия приложения

| Способ | Где | Требует |
|--------|-----|---------|
| **Siri** — «Эй, Siri, переключи прокси Telegram» | в любом приложении | iOS 17+ |
| **Shortcuts.app** — действие «Переключить прокси Telegram» (а также Start / Stop) | автоматизации, NFC-тег, виджет на экране «Домой» | iOS 17+ |
| **Пункт управления** — тоггл «Прокси Telegram» (`Настройки → Пункт управления → Добавить элементы`) | свайп вниз из правого верхнего угла | iOS 18+ |

Все три способа делают одно и то же — переключают тот же VPN-туннель, что и кнопка в приложении, и сохраняют состояние между запусками. Локальный (in-app) режим из системных контролов **не** запускается — он живёт только пока приложение активно, и поднять его из фонового процесса iOS не разрешает.

### Авто-запуск при открытии Telegram (Connect On Demand)

В `Настройки → Connect On Demand` включите тумблер «Запускать автоматически для Telegram». iOS будет поднимать VPN-прокси сам, как только система попытается разрешить любой из триггер-доменов (`telegram.org`, `t.me`, `telegram-cdn.org` и др.). Это срабатывает прозрачно при первом обращении Telegram к сети — отдельный тап не нужен.

> ⚠️ On Demand работает только в VPN-режиме (Packet Tunnel). В локальном режиме iOS не имеет туннеля, который мог бы триггериться. iOS также не позволяет триггерить On Demand по запуску конкретного приложения — ближайший доступный механизм это домены, что и используется здесь.

Чтобы по-настоящему остановить туннель при включённом On Demand, выключите либо сам тумблер On Demand в настройках приложения, либо отключите профиль в `Настройки → VPN`. Нажатие «стоп» (в приложении, Control Center или Shortcuts) временно опускает туннель и автоматически выключает On Demand, чтобы он не поднимался обратно.

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
