import SwiftUI

struct SettingsView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        TabView {
            Text("General")
                .tabItem { Label("General", systemImage: "gear") }
        }
        .frame(width: 480, height: 260)
    }
}
