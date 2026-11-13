import RaumfeldKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Raumfeld")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gear")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
                .refreshable {
                    await model.refreshStatus()
                }
        }
        .onAppear {
            if model.connection == .notConfigured { showSettings = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.connection {
        case .notConfigured:
            ContentUnavailableView {
                Label("No Raumfeld Host", systemImage: "hifispeaker.2")
            } description: {
                Text("Enter the IP address of your Raumfeld host to get started.")
            } actions: {
                Button("Open Settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
        case .connecting where model.topology.rooms.isEmpty:
            ProgressView("Connecting to \(model.host ?? "host")…")
        case let .failed(message) where model.topology.rooms.isEmpty:
            ContentUnavailableView {
                Label("Cannot Reach Raumfeld", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.connect() }
            }
        default:
            roomList
        }
    }

    private var roomList: some View {
        List {
            if case let .failed(message) = model.connection {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
            ForEach(model.topology.zones) { zone in
                Section {
                    if let first = zone.rooms.first {
                        PlaybackRow(room: first)
                    }
                    ForEach(zone.rooms) { room in
                        RoomRow(room: room)
                    }
                } header: {
                    Text(zone.displayName)
                }
            }
            if !model.topology.unassignedRooms.isEmpty {
                Section("Not Grouped") {
                    ForEach(model.topology.unassignedRooms) { room in
                        RoomRow(room: room)
                    }
                }
            }
        }
    }
}

/// Now playing plus transport buttons for a zone.
struct PlaybackRow: View {
    @Environment(AppModel.self) private var model
    let room: Room

    var body: some View {
        let nowPlaying = model.nowPlaying[model.playbackKey(for: room)]
        HStack(spacing: 12) {
            AsyncImage(url: nowPlaying?.track?.albumArtURL ?? nowPlaying?.source?.albumArtURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading) {
                Text(nowPlaying?.track?.title ?? nowPlaying?.source?.title ?? "Nothing playing")
                    .lineLimit(1)
                // For radio, show the station (the source) below the current title.
                if let artist = nowPlaying?.track?.artist ?? (nowPlaying?.track != nil ? nowPlaying?.source?.title : nil) {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { model.previous(room) } label: { Image(systemName: "backward.fill") }
            Button { model.togglePlayPause(room) } label: {
                Image(systemName: nowPlaying?.state.isPlaying == true ? "pause.fill" : "play.fill")
            }
            Button { model.next(room) } label: { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }
}

/// A room with its volume slider and mute button.
struct RoomRow: View {
    @Environment(AppModel.self) private var model
    let room: Room
    @State private var dragValue: Double?

    var body: some View {
        let volume = Double(model.volumes[room.udn] ?? 0)
        let isMuted = model.muted[room.udn] ?? false
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(room.name)
                if room.powerState?.contains("STANDBY") == true {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                Text("\(Int(dragValue ?? volume))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button { model.toggleMute(room) } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 28)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isMuted ? "Unmute \(room.name)" : "Mute \(room.name)")

                Slider(
                    value: Binding(get: { dragValue ?? volume }, set: { dragValue = $0 }),
                    in: 0...100,
                    step: 1
                ) { editing in
                    if !editing, let value = dragValue {
                        model.setVolume(Int(value), for: room)
                        dragValue = nil
                    }
                }
                .accessibilityLabel("\(room.name) volume")
            }
        }
        .padding(.vertical, 4)
    }
}
