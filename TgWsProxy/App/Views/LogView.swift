import SwiftUI
import UIKit

struct LogView: View {
    @EnvironmentObject private var controller: ProxyController

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if controller.logLines.isEmpty {
                            Text("Логи появятся после запуска прокси.")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                        ForEach(Array(controller.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                }
                .onChange(of: controller.logLines.count) { _, count in
                    if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
            .navigationTitle("Логи")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = controller.logLines.joined(separator: "\n")
                        } label: { Label("Скопировать всё", systemImage: "doc.on.doc") }
                        Button(role: .destructive) {
                            controller.clearLogs()
                        } label: { Label("Очистить", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.contains("[ERROR]") { return .red }
        if line.contains("[WARN]") { return .orange }
        if line.contains("[DEBUG]") { return .secondary }
        return .primary
    }
}
