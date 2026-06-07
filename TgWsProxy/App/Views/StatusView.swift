import SwiftUI
import UIKit

struct StatusView: View {
    @EnvironmentObject private var controller: ProxyController
    @State private var showCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    powerButton
                    statusLabel
                    if controller.isRunning {
                        statsCard
                    }
                    applyButton
                    addressCard
                }
                .padding()
            }
            .navigationTitle("TG WS Proxy")
            .background(backgroundGradient.ignoresSafeArea())
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(red: 0.04, green: 0.06, blue: 0.10), Color(red: 0.02, green: 0.10, blue: 0.14)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var powerButton: some View {
        Button(action: controller.toggle) {
            ZStack {
                Circle()
                    .fill(controller.isRunning ? Color.cyan.opacity(0.25) : Color.gray.opacity(0.15))
                    .frame(width: 180, height: 180)
                Circle()
                    .stroke(controller.isRunning ? Color.cyan : Color.gray, lineWidth: 4)
                    .frame(width: 180, height: 180)
                Image(systemName: "power")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundStyle(controller.isRunning ? Color.cyan : Color.gray)
            }
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .overlay(alignment: .bottom) {
            if isBusy { ProgressView().offset(y: 28) }
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.headline)
            .foregroundStyle(statusColor)
    }

    private var statsCard: some View {
        VStack(spacing: 6) {
            Text("Статистика")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.statsText.isEmpty ? "ожидание данных…" : controller.statsText)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var applyButton: some View {
        Button {
            applyToTelegram()
        } label: {
            Label("Применить в Telegram", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .disabled(!controller.isRunning)
    }

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Адрес", "\(controller.settings.host):\(controller.settings.port)")
            Divider()
            HStack {
                Text("Секрет").foregroundStyle(.secondary)
                Spacer()
                Text(controller.settings.secret.prefix(10) + "…")
                    .font(.system(.footnote, design: .monospaced))
                Button {
                    UIPasteboard.general.string = controller.telegramURL()?.absoluteString
                    showCopied = true
                } label: { Image(systemName: "doc.on.doc") }
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .alert("Ссылка tg:// скопирована", isPresented: $showCopied) {
            Button("OK", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    // MARK: - Actions

    private func applyToTelegram() {
        guard let url = controller.telegramURL() else { return }
        UIApplication.shared.open(url) { ok in
            if !ok {
                // No Telegram client installed that handles tg:// — copy instead.
                UIPasteboard.general.string = url.absoluteString
                showCopied = true
            }
        }
    }

    // MARK: - Derived

    private var isBusy: Bool {
        controller.state == .starting || controller.state == .stopping
    }

    private var statusText: String {
        switch controller.state {
        case .stopped:  return "Прокси остановлен"
        case .starting: return "Запуск…"
        case .running:  return "Прокси работает"
        case .stopping: return "Остановка…"
        case .failed(let m): return "Ошибка: \(m)"
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .running:  return .cyan
        case .failed:   return .red
        default:        return .secondary
        }
    }
}
