import Foundation
import XCTest
@testable import RaumfeldKit

final class ControlTests: XCTestCase {
    /// A fake Raumfeld system: answers host endpoints from fixtures, serves the
    /// zone's device description, and handles SOAP actions with `soap`.
    func makeClient(
        soap: @escaping @Sendable (RecordedRequest) -> (Int, Data)
    ) -> (RaumfeldClient, MockTransport) {
        let transport = MockTransport { request in
            let path = request.url.path
            if path.hasSuffix("/getZones") { return (200, ["updateID": "z1"], Fixture.data("getZones")) }
            if path.hasSuffix("/listDevices") { return (200, ["updateID": "d1"], Fixture.data("listDevices")) }
            if path == "/zone-1.xml" { return (200, [:], Fixture.data("zoneDescription")) }
            if request.method == "GET" { return (404, [:], Data()) }
            let (status, data) = soap(request)
            return (status, [:], data)
        }
        return (RaumfeldClient(host: "192.168.1.20", transport: transport), transport)
    }

    func testFetchTopologyUsesSessionPaths() async throws {
        let (client, transport) = makeClient { _ in (500, Data()) }
        let topology = try await client.fetchTopology()
        XCTAssertEqual(topology.zones.count, 2)
        let paths = transport.requests.map(\.url.path).sorted()
        XCTAssertEqual(paths, ["/\(client.sessionID)/getZones", "/\(client.sessionID)/listDevices"])
        XCTAssertEqual(transport.requests.first?.url.port, 47365)
        XCTAssertTrue(transport.requests.allSatisfy { $0.header("updateID") == nil })
    }

    func testSoapEnvelopeAndHeaders() async throws {
        let (client, transport) = makeClient { request in (200, soapResponse("SetRoomVolume")) }
        let topology = try await client.fetchTopology()
        try await client.room(named: "Kitchen", in: topology).setVolume(42)

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "http://192.168.1.20:47365/zone-1/RenderingControl/control")
        XCTAssertEqual(request.header("SOAPAction"), "\"urn:schemas-upnp-org:service:RenderingControl:1#SetRoomVolume\"")
        XCTAssertEqual(request.header("Content-Type"), "text/xml; charset=\"utf-8\"")
        XCTAssertTrue(request.body.contains("<u:SetRoomVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\">"))
        XCTAssertTrue(request.body.contains("<InstanceID>0</InstanceID><Room>uuid:room-kitchen</Room><DesiredVolume>42</DesiredVolume>"))
    }

    func testVolumeIsClamped() async throws {
        let (client, transport) = makeClient { _ in (200, soapResponse("SetRoomVolume")) }
        let topology = try await client.fetchTopology()
        try await client.room(named: "Kitchen", in: topology).setVolume(250)
        XCTAssertTrue(transport.requests.last!.body.contains("<DesiredVolume>100</DesiredVolume>"))
    }

    func testRoomVolumeReadsFromZone() async throws {
        let (client, _) = makeClient { request in
            XCTAssertEqual(request.soapAction, "GetRoomVolume")
            return (200, soapResponse("GetRoomVolume", ["CurrentVolume": "37"]))
        }
        let topology = try await client.fetchTopology()
        let volume = try await client.room(named: "Kitchen", in: topology).volume()
        XCTAssertEqual(volume, 37)
    }

    func testFallsBackToSpeakerWhenZoneRejectsRoomVolume() async throws {
        let (client, transport) = makeClient { request in
            if request.soapAction == "SetRoomVolume" {
                return (500, soapFault(code: 401, description: "Invalid Action"))
            }
            return (200, soapResponse(request.soapAction ?? ""))
        }
        let topology = try await client.fetchTopology()
        try await client.room(named: "Kitchen", in: topology).setVolume(20)

        let soap = transport.requests.filter { $0.method == "POST" }
        XCTAssertEqual(soap.map { $0.soapAction }, ["SetRoomVolume", "SetVolume"])
        // The speaker's description is not served, so the fallback control path is used.
        XCTAssertEqual(soap[1].url.absoluteString, "http://192.168.1.31:52240/RenderingControl/ctrl")
        XCTAssertTrue(soap[1].body.contains("<InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>20</DesiredVolume>"))
    }

    func testUnassignedRoomControlsSpeakerDirectly() async throws {
        let (client, transport) = makeClient { request in (200, soapResponse("SetMute")) }
        let topology = try await client.fetchTopology()
        try await client.room(named: "Bathroom", in: topology).setMuted(true)

        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.soapAction, "SetMute")
        XCTAssertEqual(request.url.host, "192.168.1.35")
        XCTAssertTrue(request.body.contains("<DesiredMute>1</DesiredMute>"))
    }

    func testAdjustVolume() async throws {
        let (client, transport) = makeClient { request in
            switch request.soapAction {
            case "GetRoomVolume": return (200, soapResponse("GetRoomVolume", ["CurrentVolume": "97"]))
            default: return (200, soapResponse(request.soapAction ?? ""))
            }
        }
        let topology = try await client.fetchTopology()
        let newVolume = try await client.room(named: "Kitchen", in: topology).adjustVolume(by: 10)
        XCTAssertEqual(newVolume, 100)
        XCTAssertTrue(transport.requests.last!.body.contains("<DesiredVolume>100</DesiredVolume>"))
    }

    func testSoapFaultIsSurfaced() async throws {
        let (client, _) = makeClient { _ in (500, soapFault(code: 718, description: "Invalid InstanceID")) }
        let topology = try await client.fetchTopology()
        do {
            _ = try await client.controller(for: topology.zones[0]).volume()
            XCTFail("expected an error")
        } catch let error as RaumfeldError {
            XCTAssertEqual(error, .soapFault(action: "GetVolume", code: 718, description: "Invalid InstanceID"))
        }
    }

    func testTogglePlayPauseGoesToZone() async throws {
        let (client, transport) = makeClient { request in
            if request.soapAction == "GetTransportInfo" {
                return (200, soapResponse("GetTransportInfo", ["CurrentTransportState": "PLAYING", "CurrentTransportStatus": "OK", "CurrentSpeed": "1"]))
            }
            return (200, soapResponse(request.soapAction ?? ""))
        }
        let topology = try await client.fetchTopology()
        let state = try await client.room(named: "Living Room", in: topology).togglePlayPause()
        XCTAssertEqual(state, .paused)
        let last = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(last.soapAction, "Pause")
        XCTAssertEqual(last.url.absoluteString, "http://192.168.1.20:47365/zone-1/AVTransport/control")
    }

    func testNowPlaying() async throws {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item><dc:title>Track</dc:title><upnp:artist>Band</upnp:artist></item></DIDL-Lite>
        """
        let (client, _) = makeClient { request in
            switch request.soapAction {
            case "GetTransportInfo":
                return (200, soapResponse("GetTransportInfo", ["CurrentTransportState": "PLAYING"]))
            case "GetPositionInfo":
                return (200, soapResponse("GetPositionInfo", ["Track": "3", "TrackDuration": "0:03:20", "RelTime": "0:01:00", "TrackMetaData": didl]))
            default:
                return (200, soapResponse("GetMediaInfo", ["NrTracks": "10", "CurrentURIMetaData": ""]))
            }
        }
        let topology = try await client.fetchTopology()
        let nowPlaying = try await client.room(named: "Kitchen", in: topology).nowPlaying()
        XCTAssertEqual(nowPlaying.state, .playing)
        XCTAssertEqual(nowPlaying.summary, "Track — Band")
        XCTAssertEqual(nowPlaying.position, "0:01:00")
        XCTAssertEqual(nowPlaying.duration, "0:03:20")
    }

    func testZoneConfigurationCommands() async throws {
        let transport = MockTransport { _ in (200, [:], Data()) }
        let client = RaumfeldClient(host: "192.168.1.20", transport: transport)
        try await client.connect(room: "uuid:room-bath", toZone: "uuid:zone-1")
        try await client.connect(room: "uuid:room-bath")
        try await client.drop(room: "uuid:room-kitchen")
        XCTAssertEqual(transport.requests.map(\.url.absoluteString), [
            "http://192.168.1.20:47365/connectRoomToZone?roomUDN=uuid:room-bath&zoneUDN=uuid:zone-1",
            "http://192.168.1.20:47365/connectRoomToZone?roomUDN=uuid:room-bath&zoneUDN=",
            "http://192.168.1.20:47365/dropRoomJob?roomUDN=uuid:room-kitchen",
        ])
    }

    func testTopologyUpdatesLongPollWithUpdateID() async throws {
        let calls = Counter()
        let transport = MockTransport { request in
            let n = await calls.increment(request.url.lastPathComponent)
            if n > 2 {
                // Block like an idle long poll until the test cancels.
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            if request.url.path.hasSuffix("/getZones") {
                if n == 2 {
                    // Like a real long poll, report the change only after the
                    // client has seen the first state.
                    while await calls.value("consumed") == 0 {
                        try await Task.sleep(nanoseconds: 5_000_000)
                    }
                }
                // Second response: the bathroom joined zone 2.
                let xml = n == 1
                    ? Fixture.data("getZones")
                    : Data(String(decoding: Fixture.data("getZones"), as: UTF8.self)
                        .replacingOccurrences(of: "<unassignedRooms>", with: "<unassignedRooms_>")
                        .replacingOccurrences(of: "</unassignedRooms>", with: "</unassignedRooms_>")
                        .utf8)
                return (200, ["updateID": "z\(n)"], xml)
            }
            return (200, ["updateID": "d\(n)"], Fixture.data("listDevices"))
        }
        let client = RaumfeldClient(host: "192.168.1.20", transport: transport)

        var snapshots: [Topology] = []
        for await topology in client.topologyUpdates() {
            snapshots.append(topology)
            _ = await calls.increment("consumed")
            if snapshots.count == 2 { break }
        }
        XCTAssertEqual(snapshots[0].unassignedRooms.count, 1)
        // The second zones response no longer lists unassigned rooms.
        XCTAssertEqual(snapshots[1].unassignedRooms.count, 0)

        let zoneRequests = transport.requests.filter { $0.url.path.hasSuffix("/getZones") }
        XCTAssertNil(zoneRequests[0].header("updateID"))
        XCTAssertEqual(zoneRequests[1].header("updateID"), "z1")
    }
}

actor Counter {
    private var counts: [String: Int] = [:]
    func increment(_ key: String) -> Int {
        counts[key, default: 0] += 1
        return counts[key]!
    }

    func value(_ key: String) -> Int {
        counts[key, default: 0]
    }
}
