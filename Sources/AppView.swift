import SwiftUI

struct AppView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Memory") {
                RowList(rows: model.appMemoryRows)
            }
            Section("CPU") {
                RowList(rows: model.appCPURows)
            }
            Section("Lifecycle") {
                RowList(rows: model.lifecycleRows)
            }
            Section("Signing") {
                RowList(rows: model.signingRows)
            }
            Section("Build") {
                RowList(rows: model.buildRows)
            }
            Section("Permissions") {
                RowList(rows: model.permissionRows)
            }
        }
    }
}
