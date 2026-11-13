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

    private(set) var connection: ConnectionState = .notConfigured
    private(set) var topology = Topology()
    /// Last known volume per room UDN.
    var volumes: [String: Int] = [:]
    var muted: [String: Bool] = [:]
    /// Now-playing state per zone UDN (or room UDN for unassigned rooms).
    private(set) var nowPlaying: [String: NowPlaying] = [:]

    var host: String? { AppSettings.host }

    private var client: RaumfeldClient?
    private var updatesTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var knownRoomIDs: Set<String> = []

    init() {
        connect()
    }

    /// (Re)connects to the host stored in the settings and starts following changes.
    func connect() {
        updatesTask?.cancel()
        refreshTask?.cancel()
        guard let host = AppSettings.host else {
            connection = .notConfigured
            return
        }
        connection = .connecting
        let client = RaumfeldClient(host: host)
        self.client = client

        updatesTask = Task { [weak self] in
            // A quick first fetch, so connection problems show up immediately.
            do {
                let topology = try await client.fetchTopology()
                await self?.apply(topology)
            } catch {
                self?.connection = .failed(error.localizedDescription)
            }
            // Then follow changes via long polling (retries by itself).
            for await topology in client.topologyUpdates() {
                guard let self else { return }
                await self.apply(topology)
            }
        }
        refreshTask = Task { [weak self] in
            // Volumes and playback state are not part of the long-poll; refresh them periodically.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshStatus()
            }
        }
    }

    func save(host: String) {
        AppSettings.host = host
        connect()
    }

    private func apply(_ topology: Topology) async {
        self.topology = topology
        connection = .connected
        await RaumfeldService.shared.store(topology)

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

    func refreshStatus() async {
        guard let client else { return }
        let topology = self.topology
        await withTaskGroup(of: Void.self) { group in
            for room in topology.rooms {
                let controller = client.controller(for: room, in: topology)
                group.addTask { @MainActor [weak self] in
                    if let volume = try? await controller.volume() { self?.volumes[room.udn] = volume }
                    if let muted = try? await controller.isMuted() { self?.muted[room.udn] = muted }
                }
            }
            // One now-playing request per zone, plus one per unassigned room.
            let representatives = topology.zones.compactMap(\.rooms.first) + topology.unassignedRooms
            for room in representatives {
                let controller = client.controller(for: room, in: topology)
                let key = playbackKey(for: room)
                group.addTask { @MainActor [weak self] in
                    if let nowPlaying = try? await controller.nowPlaying() { self?.nowPlaying[key] = nowPlaying }
                }
            }
        }
    }

    // MARK: Actions

    func setVolume(_ volume: Int, for room: Room) {
        volumes[room.udn] = volume
        perform(room) { try await $0.setVolume(volume) }
    }

    func toggleMute(_ room: Room) {
        let newValue = !(muted[room.udn] ?? false)
        muted[room.udn] = newValue
        perform(room) { try await $0.setMuted(newValue) }
    }

    func togglePlayPause(_ room: Room) {
        perform(room) { _ = try await $0.togglePlayPause() }
    }

    func next(_ room: Room) {
        perform(room) { try await $0.next() }
    }

    func previous(_ room: Room) {
        perform(room) { try await $0.previous() }
    }

    private func perform(_ room: Room, _ action: @escaping @Sendable (RoomController) async throws -> Void) {
        guard let controller = controller(for: room) else { return }
        Task {
            do {
                try await action(controller)
            } catch {
                connection = .failed(error.localizedDescription)
            }
            await refreshStatus()
        }
    }
}
