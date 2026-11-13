import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Entry point for talking to a Raumfeld system.
///
/// ```swift
/// let raumfeld = RaumfeldClient(host: "192.168.1.20")       // or: try await RaumfeldClient.discover()
/// let topology = try await raumfeld.fetchTopology()
/// let kitchen = try raumfeld.room(named: "Kitchen", in: topology)
/// try await kitchen.setVolume(30)
/// try await kitchen.togglePlayPause()
/// ```
public final class RaumfeldClient: Sendable {
    /// Port of the Raumfeld host's web service.
    public static let defaultPort = 47365

    /// e.g. `http://192.168.1.20:47365`
    public let baseURL: URL
    let transport: any HTTPTransport
    let resolver: ServiceResolver
    /// Long-poll requests include a session ID in the path, as the Raumfeld apps do.
    let sessionID: String

    /// How long the host may hold a long-poll request before answering.
    public var longPollTimeout: TimeInterval { 900 }

    /// Pause between long-poll requests that brought no usable change: the host
    /// answered 304 without blocking, or sent no `updateID` (so it cannot block
    /// on the next request). Keeps a misbehaving host or proxy from being
    /// hammered in a tight loop.
    let idlePollInterval: TimeInterval

    public convenience init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport.shared) {
        self.init(baseURL: baseURL, transport: transport, idlePollInterval: 5)
    }

    init(baseURL: URL, transport: any HTTPTransport, idlePollInterval: TimeInterval) {
        self.baseURL = baseURL
        self.transport = transport
        self.idlePollInterval = idlePollInterval
        self.resolver = ServiceResolver(transport: transport)
        self.sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Creates a client for the host at `host` (an IP address or host name).
    public convenience init(host: String, port: Int = RaumfeldClient.defaultPort, transport: any HTTPTransport = URLSessionTransport.shared) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        // A host name that URLComponents rejects still yields a usable fallback URL.
        let url = components.url ?? URL(string: "http://\(host):\(port)")!
        self.init(baseURL: url, transport: transport)
    }

    /// Finds the Raumfeld host via SSDP and returns a client for it.
    ///
    /// - Note: On iOS this needs the `com.apple.developer.networking.multicast`
    ///   entitlement. Without it, ask the user for the host's IP address instead.
    public static func discover(timeout: TimeInterval = 3, transport: any HTTPTransport = URLSessionTransport.shared) async throws -> RaumfeldClient {
        guard let host = try await SSDPDiscovery.findHost(timeout: timeout) else {
            throw RaumfeldError.hostNotFound
        }
        return RaumfeldClient(host: host, transport: transport)
    }

    // MARK: - Topology

    /// Fetches the current zones, rooms and devices.
    public func fetchTopology() async throws -> Topology {
        async let devicesResponse = get("listDevices", updateID: nil)
        async let zonesResponse = get("getZones", updateID: nil)
        let devices = try Topology.parseDevices(try await devicesResponse.data)
        return try Topology.parse(zones: try await zonesResponse.data, devices: devices)
    }

    /// A stream of topology snapshots. The first element is the current state;
    /// further elements arrive whenever the zone configuration or the device list
    /// changes (rooms grouped or ungrouped, speakers switched on or off, …).
    ///
    /// The stream retries on network errors and ends when the consuming task is cancelled.
    public func topologyUpdates() -> AsyncStream<Topology> {
        AsyncStream { continuation in
            let task = Task {
                await self.runLongPoll(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum PollEvent: Sendable {
        case devices([Device])
        case zones(Data)
    }

    private func runLongPoll(continuation: AsyncStream<Topology>.Continuation) async {
        let (events, eventSink) = AsyncStream<PollEvent>.makeStream()

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.poll("listDevices", sink: eventSink) { .devices(try Topology.parseDevices($0)) }
            }
            group.addTask {
                await self.poll("getZones", sink: eventSink) { data in
                    _ = try XElement.parse(data) // validate before forwarding
                    return .zones(data)
                }
            }
            group.addTask {
                var devices: [Device]?
                var zoneData: Data?
                var last: Topology?
                for await event in events {
                    switch event {
                    case let .devices(newDevices): devices = newDevices
                    case let .zones(data): zoneData = data
                    }
                    guard let devices, let zoneData,
                          let topology = try? Topology.parse(zones: zoneData, devices: devices),
                          topology != last
                    else { continue }
                    last = topology
                    continuation.yield(topology)
                }
            }
            // Child tasks inherit cancellation from the stream's task, so the
            // group finishes once the consumer stops listening.
        }
        continuation.finish()
    }

    private func poll(_ endpoint: String, sink: AsyncStream<PollEvent>.Continuation, parse: (Data) throws -> PollEvent) async {
        var updateID: String?
        var failures = 0
        while !Task.isCancelled {
            do {
                let response = try await get(endpoint, updateID: updateID, longPoll: true)
                failures = 0
                if response.statusCode == 304 {
                    // "No change". A host that blocks first is fine; one that
                    // answers immediately must not be asked again right away.
                    try await Task.sleep(nanoseconds: UInt64(idlePollInterval * 1_000_000_000))
                    continue
                }
                sink.yield(try parse(response.data))
                updateID = response.updateID
                if updateID == nil {
                    // Without an updateID the next request cannot block, so fall
                    // back to plain polling.
                    try await Task.sleep(nanoseconds: UInt64(idlePollInterval * 1_000_000_000))
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                // Timeouts are expected for idle long polls; start over with a fresh state.
                updateID = nil
                failures += 1
                let delay = min(30, 1 << min(failures, 5)) // 2, 4, 8, 16, 30 s
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }
        }
    }

    private struct HostResponse: Sendable {
        var data: Data
        var statusCode: Int
        var updateID: String?
    }

    private func get(_ endpoint: String, updateID: String?, longPoll: Bool = false) async throws -> HostResponse {
        let url = baseURL.appendingPathComponent(sessionID).appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.timeoutInterval = longPoll ? longPollTimeout : 10
        if let updateID {
            request.setValue(updateID, forHTTPHeaderField: "updateID")
        }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) || response.statusCode == 304 else {
            throw RaumfeldError.httpStatus(response.statusCode, url: url)
        }
        return HostResponse(
            data: data,
            statusCode: response.statusCode,
            updateID: response.value(forHTTPHeaderField: "updateID")
        )
    }

    // MARK: - Zone configuration

    /// Moves `room` into the zone `zone`, or into a new zone of its own if `zone` is `nil`.
    public func connect(room roomUDN: String, toZone zoneUDN: String? = nil) async throws {
        try await hostCommand("connectRoomToZone", [
            URLQueryItem(name: "roomUDN", value: roomUDN),
            URLQueryItem(name: "zoneUDN", value: zoneUDN ?? ""),
        ])
    }

    /// Removes `room` from its zone.
    public func drop(room roomUDN: String) async throws {
        try await hostCommand("dropRoomJob", [URLQueryItem(name: "roomUDN", value: roomUDN)])
    }

    private func hostCommand(_ path: String, _ query: [URLQueryItem]) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let url = components.url!
        let (_, response) = try await transport.send(URLRequest(url: url))
        guard (200..<300).contains(response.statusCode) else {
            throw RaumfeldError.httpStatus(response.statusCode, url: url)
        }
    }

    // MARK: - Controllers

    /// A controller for one room. Playback commands go to the room's zone.
    public func controller(for room: Room, in topology: Topology) -> RoomController {
        RoomController(client: self, room: room, zone: topology.zone(containing: room))
    }

    /// A controller for a whole zone.
    public func controller(for zone: Zone) -> ZoneController {
        ZoneController(client: self, zone: zone)
    }

    /// Looks up a room by name (see `Topology.room(named:)`) and returns its controller.
    public func room(named name: String, in topology: Topology) throws -> RoomController {
        guard let room = topology.room(named: name) else { throw RaumfeldError.notFound("Room \"\(name)\"") }
        return controller(for: room, in: topology)
    }

    /// RenderingControl of the device at `location`. `kind` selects the fallback
    /// control path used if the device description cannot be fetched.
    public func renderingControl(at location: URL, kind: DeviceKind = .renderer) async -> RenderingControl {
        RenderingControl(soap: await resolver.service(.renderingControl, at: location, kind: kind))
    }

    public func avTransport(at location: URL, kind: DeviceKind = .renderer) async -> AVTransport {
        AVTransport(soap: await resolver.service(.avTransport, at: location, kind: kind))
    }

    /// The media server's ContentDirectory (browse, search and queues).
    public func contentDirectory(in topology: Topology) async throws -> ContentDirectory {
        guard let server = topology.mediaServer else { throw RaumfeldError.notFound("Raumfeld MediaServer") }
        return ContentDirectory(soap: await resolver.service(.contentDirectory, at: server.location, kind: .mediaServer))
    }
}
