import SwiftUI

struct DeviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Model") {
                RowList(rows: model.modelRows)
            }
            Section("CPU / GPU / RAM") {
                RowList(rows: model.chipRows)
            }
            Section("System CPU / RAM (live)") {
                RowList(rows: model.systemLiveRows)
            }
            Section("Storage") {
                RowList(rows: model.storageRows)
            }
            Section("Display") {
                RowList(rows: model.displayRows)
            }
            Section("Power / Thermal") {
                RowList(rows: model.powerRows)
            }
        }
    }
}
