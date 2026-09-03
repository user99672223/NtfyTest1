import SwiftUI

struct TestView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List {
            Section("URL scheme") {
                LabeledContent("Scheme", value: "ntfytest://")
                LabeledContent("Example", value: "ntfytest://open?id=...&t=...")
            }
            Section("ntfy") {
                TextField("topic", text: $model.topic)
                Text("Install the ntfy app, subscribe to this topic, then tap Send.")
            }
            Section {
                Button("Send test notification") { model.sendOne() }
                if !model.sendResult.isEmpty { Text(model.sendResult) }
                Button("Send 5, every 5 s") { model.sendBurst() }
                if !model.burstResult.isEmpty { Text(model.burstResult) }
            }
            Section("Last open") {
                RowList(rows: model.lastOpenRows)
            }
            Section("History") {
                ForEach(model.history) { event in
                    LabeledContent(event.timeText + " · " + event.latencyText, value: event.url)
                }
                Button("Clear") { model.clearHistory() }
            }
        }
        .onChange(of: model.topic) { _, _ in model.persistTopic() }
    }
}
