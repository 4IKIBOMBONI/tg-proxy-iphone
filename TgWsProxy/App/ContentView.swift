import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: ProxyController

    var body: some View {
        TabView {
            StatusView()
                .tabItem { Label("Главная", systemImage: "bolt.horizontal.circle") }

            LogView()
                .tabItem { Label("Логи", systemImage: "text.alignleft") }

            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }

            InfoView()
                .tabItem { Label("Инфо", systemImage: "info.circle") }
        }
        .tint(.cyan)
    }
}

#Preview {
    ContentView().environmentObject(ProxyController())
}
