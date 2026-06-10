import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: ProxyController
    /// Drives the keyboard-dismiss toolbar. The exact field identity doesn't
    /// matter — we only need *some* focus state to feed the system's "is the
    /// keyboard up" signal so the "Готово" button shows.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case port, cfDomain, fakeTlsDomain, dcIps, onDemandDomains
    }

    private var poolBinding: Binding<Double> {
        Binding(
            get: { Double(controller.settings.poolSize) },
            set: { controller.settings.poolSize = Int($0) }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Изменения применятся при следующем запуске прокси.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Режим работы") {
                    Picker("Режим", selection: $controller.settings.backgroundMode) {
                        ForEach(BackgroundMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Text(controller.settings.backgroundMode.subtitle)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if controller.settings.backgroundMode == .vpn {
                    Section {
                        Toggle("Запускать автоматически для Telegram",
                               isOn: $controller.settings.onDemandEnabled)
                        if controller.settings.onDemandEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Домены-триггеры")
                                    .font(.footnote).foregroundStyle(.secondary)
                                TextField(ProxySettings.defaultOnDemandDomains.joined(separator: ", "),
                                          text: $controller.settings.onDemandDomains,
                                          axis: .vertical)
                                    .font(.system(.footnote, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .lineLimit(2...4)
                                    .focused($focusedField, equals: .onDemandDomains)
                                Text("Пусто — использовать список по умолчанию (\(ProxySettings.defaultOnDemandDomains.count) доменов Telegram).")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Connect On Demand")
                    } footer: {
                        Text("iOS поднимет VPN-прокси автоматически, как только система попытается разрешить любой из этих доменов — то есть при первом обращении Telegram к сети. Работает только в VPN-режиме.")
                    }
                }

                Section("Локальный прокси") {
                    HStack {
                        Text("Порт")
                        Spacer()
                        TextField("1443", value: $controller.settings.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .focused($focusedField, equals: .port)
                    }
                    VStack(alignment: .leading) {
                        Text("Секрет (16 байт, hex)")
                        HStack {
                            Text(controller.settings.secret)
                                .font(.system(.footnote, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Сгенерировать") { controller.regenerateSecret() }
                                .font(.footnote)
                        }
                        if !controller.settings.isSecretValid {
                            Text("Секрет должен быть 32 hex-символа")
                                .font(.caption2).foregroundStyle(.red)
                        }
                    }
                }

                Section("Пул WS-соединений") {
                    VStack(alignment: .leading) {
                        Text("Размер пула: \(controller.settings.poolSize)")
                        Slider(value: poolBinding, in: 2...16, step: 1)
                    }
                }

                Section("CloudFlare") {
                    Toggle("Использовать CloudFlare", isOn: $controller.settings.cfproxyEnabled)
                    HStack {
                        Text("Свой домен")
                        Spacer()
                        TextField("необязательно", text: $controller.settings.cfproxyUserDomain)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .cfDomain)
                    }
                }

                Section("FakeTLS (ee-secret)") {
                    Toggle("Включить FakeTLS", isOn: $controller.settings.fakeTlsEnabled)
                    if controller.settings.fakeTlsEnabled {
                        HStack {
                            Text("SNI-домен")
                            Spacer()
                            TextField("www.google.com", text: $controller.settings.fakeTlsDomain)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($focusedField, equals: .fakeTlsDomain)
                        }
                    }
                }

                Section("Дополнительно") {
                    Toggle("Подробные логи", isOn: $controller.settings.verboseLogging)
                    VStack(alignment: .leading) {
                        Text("DC → IP (вручную)")
                        TextField("2:149.154.167.220,4:149.154.167.220",
                                  text: $controller.settings.dcIps)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .dcIps)
                        Text("Пусто — использовать встроенные адреса ядра.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .onDisappear { controller.saveSettings() }
            // Dragging the form down dismisses the keyboard — this is the
            // standard SwiftUI gesture users expect on iOS, and it's the
            // only way to close a numeric keyboard that has no Return key.
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // "Готово" button above the keyboard. SwiftUI shows the
                // .keyboard placement only while *some* field is focused,
                // so it appears for every TextField in the form.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { focusedField = nil }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
