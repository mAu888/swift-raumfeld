import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import XCTest
@testable import RaumfeldKit

/// Tests for the robustness fixes: fallback paths, description caching,
/// long-poll throttling, cancellation and number parsing.
final class ReviewFixTests: XCTestCase {
    // MARK: Fallback control paths

    func testFallbackPathsDependOnDeviceKind() {
        let location = URL(string: "http://10.0.0.5:47365/zone.xml")!
        func path(_ service: UPnPService, _ kind: DeviceKind) -> String {
            ServiceResolver.fallbackURL(for: service, kind: kind, location: location).path
        }
        XCTAssertEqual(path(.renderingControl, .zone), "/RenderingService/Control")
        XCTAssertEqual(path(.avTransport, .zone), "/TransportService/Control")
        XCTAssertEqual(path(.renderingControl, .renderer), "/RenderingControl/ctrl")
        XCTAssertEqual(path(.avTransport, .renderer), "/AVTransport/ctrl")
        XCTAssertEqual(path(.contentDirectory, .mediaServer), "/cd/Control")
    }

    /// A system where no device serves its description.
    func makeClientWithoutDescriptions(
        soap: @escaping @Sendable (RecordedRequest) -> (Int, Data) = { (200, soapResponse($0.soapAction ?? "")) }
    ) -> (RaumfeldClient, MockTransport) {
        let transport = MockTransport { request in
            let path = request.url.path
            if path.hasSuffix("/getZones") { return (200, [:], Fixture.data("getZones")) }
            if path.hasSuffix("/listDevices") { return (200, [:], Fixture.data("listDevices")) }
            if request.method == "GET" { return (404, [:], Data()) }
            let (status, data) = soap(request)
            return (status, [:], data)
        }
        return (RaumfeldClient(host: "192.168.1.20", transport: transport), transport)
    }

    func testZoneCommandsUseZoneFallbackPaths() async throws {
        let (client, transport) = makeClientWithoutDescriptions { request in
            if request.soapAction == "GetTransportInfo" {
                return (200, soapResponse("GetTransportInfo", ["CurrentTransportState": "STOPPED"]))
            }
            return (200, soapResponse(request.soapAction ?? ""))
        }
        let topology = try await client.fetchTopology()
        let kitchen = try client.room(named: "Kitchen", in: topology)
        try await kitchen.setVolume(10)
        try await kitchen.togglePlayPause()
        try await client.controller(for: topology.zones[0]).setVolume(20)

        let soap = transport.requests.filter { $0.method == "POST" }
        XCTAssertEqual(soap.map(\.soapAction), ["SetRoomVolume", "GetTransportInfo", "Play", "SetVolume"])
        XCTAssertEqual(soap.map(\.url.path), [
            "/RenderingService/Control",
            "/TransportService/Control",
            "/TransportService/Control",
            "/RenderingService/Control",
        ])
    }

    func testUnassignedRoomUsesSpeakerFallbackPaths() async throws {
        let (client, transport) = makeClientWithoutDescriptions()
        let topology = try await client.fetchTopology()
        try await client.room(named: "Bathroom", in: topology).play()
        XCTAssertEqual(transport.requests.last?.url.absoluteString, "http://192.168.1.35:52240/AVTransport/ctrl")
    }

    // MARK: Description cache

    func testFailedDescriptionIsCachedAndConcurrentLookupsShareOneRequest() async throws {
        let transport = MockTransport { _ in
            try await Task.sleep(nanoseconds: 50_000_000)
            return (404, [:], Data())
        }
        let resolver = ServiceResolver(transport: transport)
        let location = URL(string: "http://10.0.0.9:52240/description.xml")!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask { _ = await resolver.service(.renderingControl, at: location, kind: .renderer) }
            }
        }
        XCTAssertEqual(transport.requests.count, 1, "concurrent lookups share one request")

        let service = await resolver.service(.avTransport, at: location, kind: .renderer)
        XCTAssertEqual(transport.requests.count, 1, "the failure is remembered")
        XCTAssertEqual(service.controlURL.path, "/AVTransport/ctrl")
    }

    func testFailedDescriptionIsRetriedAfterTTL() async throws {
        let transport = MockTransport { _ in (404, [:], Data()) }
        let resolver = ServiceResolver(transport: transport, failureTTL: 0)
        let location = URL(string: "http://10.0.0.9:52240/description.xml")!
        _ = await resolver.service(.renderingControl, at: location, kind: .renderer)
        _ = await resolver.service(.renderingControl, at: location, kind: .renderer)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testSuccessfulDescriptionIsCached() async throws {
        let transport = MockTransport { _ in (200, [:], Fixture.data("zoneDescription")) }
        let resolver = ServiceResolver(transport: transport)
        let location = URL(string: "http://192.168.1.20:47365/zone-1.xml")!
        _ = await resolver.service(.renderingControl, at: location, kind: .zone)
        let service = await resolver.service(.avTransport, at: location, kind: .zone)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(service.controlURL.path, "/zone-1/AVTransport/control")
    }

    // MARK: Long polling

    func testPollingIsThrottledWithoutUpdateID() async throws {
        // A host that never sends an updateID cannot block, so the client must
        // not re-request immediately.
        let transport = MockTransport { request in
            if request.url.path.hasSuffix("/getZones") { return (200, [:], Fixture.data("getZones")) }
            return (200, [:], Fixture.data("listDevices"))
        }
        let client = RaumfeldClient(baseURL: URL(string: "http://192.168.1.20:47365")!, transport: transport, idlePollInterval: 0.5)

        let consumer = Task {
            for await _ in client.topologyUpdates() {}
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()

        let zoneRequests = transport.requests.filter { $0.url.path.hasSuffix("/getZones") }
        XCTAssertEqual(zoneRequests.count, 1, "the second request waits for idlePollInterval")
    }

    func testPollingIsThrottledOnImmediate304() async throws {
        let calls = Counter()
        let transport = MockTransport { request in
            let n = await calls.increment(request.url.lastPathComponent)
            if n > 1 { return (304, ["updateID": "1"], Data()) }
            if request.url.path.hasSuffix("/getZones") { return (200, ["updateID": "1"], Fixture.data("getZones")) }
            return (200, ["updateID": "1"], Fixture.data("listDevices"))
        }
        let client = RaumfeldClient(baseURL: URL(string: "http://192.168.1.20:47365")!, transport: transport, idlePollInterval: 0.5)

        let consumer = Task {
            for await _ in client.topologyUpdates() {}
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        consumer.cancel()

        let zoneRequests = transport.requests.filter { $0.url.path.hasSuffix("/getZones") }
        XCTAssertEqual(zoneRequests.count, 2, "one 200, then one 304 followed by a pause")
    }

    func testStoppingTheStreamCancelsInFlightLongPolls() async throws {
        let counter = Counter()
        let transport = MockTransport { request in
            if request.header("updateID") != nil {
                // An idle long poll: block until cancelled.
                _ = await counter.increment("blocking")
                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    _ = await counter.increment("cancelled")
                    throw error
                }
            }
            if request.url.path.hasSuffix("/getZones") { return (200, ["updateID": "1"], Fixture.data("getZones")) }
            return (200, ["updateID": "1"], Fixture.data("listDevices"))
        }
        let client = RaumfeldClient(host: "192.168.1.20", transport: transport)

        // Let at least one long poll start blocking before the consumer stops.
        for await _ in client.topologyUpdates() {
            for _ in 0..<100 where await counter.value("blocking") == 0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            break
        }
        // Every request that was blocking must be cancelled, well before its 60 s sleep ends.
        for _ in 0..<200 {
            let blocking = await counter.value("blocking")
            if blocking > 0, await counter.value("cancelled") == blocking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let blocking = await counter.value("blocking")
        let cancelled = await counter.value("cancelled")
        XCTAssertGreaterThan(blocking, 0)
        XCTAssertEqual(cancelled, blocking)
    }

    // MARK: URLSessionTransport

    func testLongPollRequestsUseLongPollSession() {
        let transport = URLSessionTransport()
        var request = URLRequest(url: URL(string: "http://127.0.0.1/")!)
        request.timeoutInterval = 10
        XCTAssertTrue(transport.session(for: request) === transport.session)
        request.timeoutInterval = 900
        XCTAssertTrue(transport.session(for: request) === transport.longPollSession)
        XCTAssertEqual(transport.longPollSession.configuration.timeoutIntervalForRequest, 1200)
    }

    func testCancellingTheTaskCancelsTheRequest() async throws {
        // A TCP server that accepts connections but never answers.
        let server = try SilentServer()
        defer { server.close() }

        let transport = URLSessionTransport()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/hang")!)
        request.timeoutInterval = 900
        let started = Date()
        let task = Task { try await transport.send(request) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Number parsing

    func testIntegersWithWhitespaceAreParsed() async throws {
        let (client, _) = makeClientWithoutDescriptions { request in
            switch request.soapAction {
            case "GetPositionInfo":
                return (200, soapResponse("GetPositionInfo", ["Track": " 1 ", "TrackDuration": "0:01:00", "RelTime": "0:00:10"]))
            case "GetMediaInfo":
                return (200, soapResponse("GetMediaInfo", ["NrTracks": "\n3\n"]))
            default:
                return (200, soapResponse("GetRoomVolume", ["CurrentVolume": "\n 42\n"]))
            }
        }
        let topology = try await client.fetchTopology()
        let transport = try await client.room(named: "Kitchen", in: topology).transport()
        let position = try await transport.positionInfo()
        let media = try await transport.mediaInfo()
        XCTAssertEqual(position.track, 1)
        XCTAssertEqual(media.numberOfTracks, 3)
        let volume = try await client.room(named: "Kitchen", in: topology).volume()
        XCTAssertEqual(volume, 42)
    }
}

/// Listens on a random local port and accepts connections without ever replying.
final class SilentServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private var clients: [Int32] = []
    private let queue = DispatchQueue(label: "SilentServer")

    init() throws {
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw RaumfeldError.invalidResponse("cannot listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        queue.async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                self?.clients.append(client)
            }
        }
    }

    func close() {
        shutdown(fd, Int32(SHUT_RDWR))
        #if canImport(Glibc)
        Glibc.close(fd)
        #else
        Darwin.close(fd)
        #endif
    }
}
