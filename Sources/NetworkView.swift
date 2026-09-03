import SwiftUI

struct NetworkView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section("Path") {
                RowList(rows: model.pathRows)
            }
            Section("Interfaces") {
                ForEach(model.interfaceGroups) { group in
                    RowList(rows: group.rows)
                }
            }
            Section("Public IP") {
                LabeledContent("api64.ipify.org", value: model.publicIP)
                Button("Refresh") { Task { await model.refreshPublicIP() } }
            }
            Section("Latency test") {
                TextField("host", text: $model.latencyHost)
                TextField("port", text: $model.latencyPort)
                Button("Test") { Task { await model.runLatencyTest() } }
                LabeledContent("Result", value: model.latencyResult)
            }
        }
        .task { await model.refreshPublicIP() }
    }
}
