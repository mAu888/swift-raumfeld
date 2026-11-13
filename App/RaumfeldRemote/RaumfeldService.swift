import Foundation
import RaumfeldKit

/// User settings shared by the app UI and the App Intents.
///
/// If you add a widget or Control Center extension later, move these into an
/// App Group (`UserDefaults(suiteName:)`) so the extension can read them too.
enum AppSettings {
    private static let hostKey = "raumfeldHost"

    static var host: String? {
        get {
            let value = UserDefaults.standard.string(forKey: hostKey)?.trimmingCharacters(in: .whitespaces)
            return value?.isEmpty == false ? value : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }
}

enum RemoteError: Error, LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Open Raumfeld Remote and enter the address of your Raumfeld host first."
        }
    }
}

/// Owns the `RaumfeldClient` and a cached topology.
///
/// App Intents run without the UI, often in a freshly launched process, so they
/// get the topology from here: a cached copy if it is recent, otherwise a fresh
/// fetch (one quick HTTP round trip to the host).
actor RaumfeldService {
    static let shared = RaumfeldService()

    private var client: RaumfeldClient?
    private var clientHost: String?
    private var topology: Topology?
    private var topologyDate: Date?

    func currentClient() throws -> RaumfeldClient {
        guard let host = AppSettings.host else { throw RemoteError.notConfigured }
        if let client, clientHost == host { return client }
        let newClient = RaumfeldClient(host: host)
        client = newClient
        clientHost = host
        topology = nil
        return newClient
    }

    /// Returns the topology, refetching it if it is older than `maxAge` seconds.
    func topology(maxAge: TimeInterval = 15) async throws -> Topology {
        let client = try currentClient()
        if let topology, let topologyDate, Date().timeIntervalSince(topologyDate) < maxAge {
            return topology
        }
        let fresh = try await client.fetchTopology()
        store(fresh)
        return fresh
    }

    /// Called by the app's long-poll loop so intents can reuse the latest state.
    func store(_ topology: Topology) {
        self.topology = topology
        self.topologyDate = Date()
    }

    /// A controller for the room with the given UDN. Refetches the topology once
    /// if the room is unknown (e.g. it was just regrouped).
    func controller(forRoom udn: String) async throws -> RoomController {
        let client = try currentClient()
        var topology = try await topology()
        if topology.room(udn: udn) == nil {
            topology = try await self.topology(maxAge: 0)
        }
        guard let room = topology.room(udn: udn) else { throw RaumfeldError.notFound("That room") }
        return client.controller(for: room, in: topology)
    }

    func rooms() async throws -> [Room] {
        try await topology().rooms
    }
}
