import SwiftUI

@main
struct NtfyTestApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                TestView()
                    .tabItem { Label("Test", systemImage: "bell") }
                NetworkView()
                    .tabItem { Label("Network", systemImage: "network") }
                AppView()
                    .tabItem { Label("App", systemImage: "app.badge") }
                DeviceView()
                    .tabItem { Label("Device", systemImage: "iphone") }
            }
            .environment(model)
            .onOpenURL { url in model.handleOpen(url) }
            .onChange(of: scenePhase) { _, phase in model.setScenePhase(phase) }
        }
    }
}

struct RowList: View {
    let rows: [Row]

    var body: some View {
        ForEach(rows) { row in
            LabeledContent(row.label, value: row.value)
        }
    }
}
