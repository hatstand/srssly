import SrsslyKeys
import SwiftUI

/// App settings, shown as a sheet from the main toolbar.
struct SettingsView: View {
    @AppStorage(OfflineSettings.allowsCellularKey) private var allowsCellular = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Download on Mobile Data", isOn: $allowsCellular)
                } header: {
                    Text("Offline Reading")
                } footer: {
                    Text("Recent articles, their images and, for feeds that only send a summary, the full page are saved for reading offline. This happens on Wi-Fi unless you allow mobile data. Feeds always refresh on any network.")
                }
                Section("About") {
                    // From the Rust key core, so this also shows it is linked in.
                    LabeledContent("Key Format", value: String(SrsslyKeys.formatVersion()))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

#Preview {
    SettingsView()
}
