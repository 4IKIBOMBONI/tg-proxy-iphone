import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var controller: ProxyController

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

                Section("Локальный прокси") {
                    HStack {
                        Text("Порт")
                        Spacer()
                        TextField("1443", value: $controller.settings.port, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
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
                        Text("Пусто — использовать встроенные адреса ядра.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .onDisappear { controller.saveSettings() }
        }
    }
}
