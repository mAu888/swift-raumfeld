import AppIntents
import RaumfeldKit

/// A Raumfeld room as seen by Siri, Shortcuts and Spotlight.
struct RoomEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Room"
    static var defaultQuery = RoomQuery()

    /// The room's UDN. It stays the same when rooms are regrouped.
    var id: String
    var name: String
    var zoneName: String?

    var displayRepresentation: DisplayRepresentation {
        if let zoneName, zoneName != name {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(zoneName)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    init(id: String, name: String, zoneName: String? = nil) {
        self.id = id
        self.name = name
        self.zoneName = zoneName
    }

    init(room: Room, topology: Topology) {
        self.init(id: room.udn, name: room.name, zoneName: topology.zone(containing: room)?.displayName)
    }
}

struct RoomQuery: EntityStringQuery {
    func entities(for identifiers: [RoomEntity.ID]) async throws -> [RoomEntity] {
        let topology = try await RaumfeldService.shared.topology()
        return identifiers.compactMap { id in
            topology.room(udn: id).map { RoomEntity(room: $0, topology: topology) }
        }
    }

    /// The rooms Siri offers and matches spoken room names against.
    func suggestedEntities() async throws -> [RoomEntity] {
        let topology = try await RaumfeldService.shared.topology()
        return topology.rooms.map { RoomEntity(room: $0, topology: topology) }
    }

    func entities(matching string: String) async throws -> [RoomEntity] {
        let topology = try await RaumfeldService.shared.topology()
        let all = topology.rooms
        let matches = all.filter { $0.name.localizedCaseInsensitiveContains(string) }
        // Fall back to the library's fuzzy match (diacritics, prefixes).
        let result = matches.isEmpty ? topology.room(named: string).map { [$0] } ?? [] : matches
        return result.map { RoomEntity(room: $0, topology: topology) }
    }
}
