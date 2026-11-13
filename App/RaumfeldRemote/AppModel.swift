import AppIntents
import Foundation
import Observation
import RaumfeldKit

@MainActor
@Observable
final class AppModel {
    enum ConnectionState: Equatable {
        case notConfigured
        case connecting
        case connected
        case failed(String)
    }

    /// How often volumes and playback state are refreshed while the app is in
    /// the foreground. They are not part of the host's long poll.
    static let statusRefreshInterval: UInt64 = 10_000_000_000

    private(set) var connection: ConnectionState = .notConfigured
    private(set) var topology = Topology()
    /// Last known volume per room UDN.
    var volumes: [String: Int] = [:]
    var muted: [String: Bool] = [:]
    /// Now-playing state per zone UDN (or room UDN for unassigned rooms).
    private(set) var nowPlaying: [String: NowPlaying] = [:]

    var host: String? { AppSettings.host }

    private var client: RaumfeldClient?
    /// Incremented on every (re)connect. Work started for an older generation
    /// must not touch the model, because it belongs to a previous host.
    private var generation = 0
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var isActive = true
    private var isRefreshing = false
    private var knownRoomIDs: Set<String> = []

    init() {
        connect()
    }

    /// (Re)connects to the host stored in the settings and starts following changes.
    func connect() {
        generation += 1
        let generation = self.generation
        updatesTask?.cancel()
        stopRefreshing()
        client = nil
        topology = Topology()
        volumes = [:]
        muted = [:]
        nowPlaying = [:]

        guard AppSettings.host != nil else {
            connection = .notConfigured
            return
        }
        connection = .connecting

        updatesTask = Task { [weak self] in
            // Shared with the App Intents, so there is one client (and one
            // URLSession) per host.
            guard let client = try? await RaumfeldService.shared.currentClient() else { return }
            guard let self, self.generation == generation else { return }
            self.client = client

            // A quick first fetch, so connection problems show up immediately.
            do {
                let topology = try await client.fetchTopology()
                await self.apply(topology, from: client, generation: generation)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.connection = .failed(error.localizedDescription)
            }
            // Then follow changes via long polling (retries by itself).
            for await topology in client.topologyUpdates() {
                guard !Task.isCancelled else { return }
                await self.apply(topology, from: client, generation: generation)
            }
        }
        if isActive { startRefreshing() }
    }

    func save(host: String) {
        AppSettings.host = host
        connect()
    }

    /// Called when the app moves between foreground and background. Status
    /// polling only runs in the foreground.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startRefreshing()
        } else {
            stopRefreshing()
        }
    }

    private func startRefreshing() {
        stopRefreshing()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.statusRefreshInterval)
                guard !Task.isCancelled else { return }
                await self?.refreshStatus()
            }
        }
    }

    private func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func apply(_ topology: Topology, from client: RaumfeldClient, generation: Int) async {
        guard !Task.isCancelled, generation == self.generation else { return }
        self.topology = topology
        connection = .connected
        await RaumfeldService.shared.store(topology, from: client)

        // Let Siri learn new room names for the App Shortcut phrases.
        let roomIDs = Set(topology.rooms.map(\.udn))
        if roomIDs != knownRoomIDs {
            knownRoomIDs = roomIDs
            RaumfeldShortcuts.updateAppShortcutParameters()
        }
        await refreshStatus()
    }

    func controller(for room: Room) -> RoomController? {
        client?.controller(for: room, in: topology)
    }

    /// Key under which `nowPlaying` is stored for a room.
    func playbackKey(for room: Room) -> String {
        room.zoneUDN ?? room.udn
    }

    /// Refreshes volume, mute and now playing for all rooms. Overlapping calls
    /// are skipped instead of piling up requests.
    func refreshStatus() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // One now-playing request per zone, plus one per unassigned room.
        let representatives = topology.zones.compactMap(\.rooms.first) + topology.unassignedRooms
        await refresh(volumeOf: topology.rooms, playbackOf: representatives)
    }

    /// Refreshes only what a command on `room` can have changed.
    private func refreshAfterCommand(on room: Room, volume: Bool, playback: Bool) async {
        await refresh(volumeOf: volume ? [room] : [], playbackOf: playback ? [room] : [])
    }

    private func refresh(volumeOf volumeRooms: [Room], playbackOf playbackRooms: [Room]) async {
        guard let client else { return }
        let topology = self.topology
        let generation = self.generation
        var succeeded = false

        await withTaskGroup(of: Bool.self) { group in
            for room in volumeRooms {
                let controller = client.controller(for: room, in: topology)
                group.addTask { @MainActor [weak self] in
                    async let volume = try? controller.volume()
                    async let muted = try? controller.isMuted()
                    let (v, m) = await (volume, muted)
                    guard let self, self.generation == generation else { return false }
                    if let v { self.volumes[room.udn] = v }
                    if let m { self.muted[room.udn] = m }
                    return v != nil
                }
            }
            for room in playbackRooms {
                let controller = client.controller(for: room, in: topology)
                let key = playbackKey(for: room)
                group.addTask { @MainActor [weak self] in
                    let nowPlaying = try? await controller.nowPlaying()
                    guard let self, let nowPlaying, self.generation == generation else { return false }
                    self.nowPlaying[key] = nowPlaying
                    return true
                }
            }
            for await result in group where result { succeeded = true }
        }

        // The system is reachable again: clear an error left by an earlier command.
        if succeeded, generation == self.generation, case .failed = connection {
            connection = .connected
        }
    }

    // MARK: Actions

    func setVolume(_ volume: Int, for room: Room) {
        volumes[room.udn] = volume
        perform(room, volume: true, playback: false) { try await $0.setVolume(volume) }
    }

    func toggleMute(_ room: Room) {
        let newValue = !(muted[room.udn] ?? false)
        muted[room.udn] = newValue
        perform(room, volume: true, playback: false) { try await $0.setMuted(newValue) }
    }

    func togglePlayPause(_ room: Room) {
        perform(room, volume: false, playback: true) { _ = try await $0.togglePlayPause() }
    }

    func next(_ room: Room) {
        perform(room, volume: false, playback: true) { try await $0.next() }
    }

    func previous(_ room: Room) {
        perform(room, volume: false, playback: true) { try await $0.previous() }
    }

    private func perform(
        _ room: Room,
        volume: Bool,
        playback: Bool,
        _ action: @escaping @Sendable (RoomController) async throws -> Void
    ) {
        guard let controller = controller(for: room) else { return }
        let generation = self.generation
        Task {
            do {
                try await action(controller)
                if generation == self.generation, case .failed = connection {
                    connection = .connected
                }
            } catch {
                guard generation == self.generation else { return }
                connection = .failed(error.localizedDescription)
            }
            guard generation == self.generation else { return }
            await refreshAfterCommand(on: room, volume: volume, playback: playback)
        }
    }
}
