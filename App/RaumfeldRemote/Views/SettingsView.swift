import AppIntents
import RaumfeldKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = AppSettings.host ?? ""
    @State private var searching = false
    @State private var searchMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.20", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("Search Network")
                            if searching { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(searching)
                    if let searchMessage {
                        Text(searchMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Raumfeld Host")
                } footer: {
                    Text("The IP address of the Raumfeld host (the device that runs the system, usually your base or a connector). You can find it in your router's device list.")
                }

                Section {
                    ShortcutsLink()
                    SiriTipView(intent: ChangeVolumeIntent(direction: .up))
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    Text("Try \u{201C}Turn up Kitchen with Raumfeld Remote\u{201D} or \u{201C}What's playing on Raumfeld Remote\u{201D}. All actions are also available in the Shortcuts app.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.save(host: host)
                        dismiss()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func search() async {
        searching = true
        searchMessage = nil
        defer { searching = false }
        do {
            if let found = try await SSDPDiscovery.findHost(timeout: 3) {
                host = found
                searchMessage = "Found \(found)."
            } else {
                searchMessage = "No host found. Automatic search needs the multicast entitlement; enter the address manually."
            }
        } catch {
            searchMessage = "Search failed: \(error.localizedDescription)"
        }
    }
}
