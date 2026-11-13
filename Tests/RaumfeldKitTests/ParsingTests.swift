import XCTest
@testable import RaumfeldKit

final class ParsingTests: XCTestCase {
    func makeTopology() throws -> Topology {
        let devices = try Topology.parseDevices(Fixture.data("listDevices"))
        return try Topology.parse(zones: Fixture.data("getZones"), devices: devices)
    }

    func testParsesDevices() throws {
        let devices = try Topology.parseDevices(Fixture.data("listDevices"))
        XCTAssertEqual(devices.count, 8)
        XCTAssertEqual(devices[0].udn, "uuid:zone-1")
        XCTAssertEqual(devices[0].name, "Kitchen & Living Room")
        XCTAssertEqual(devices[0].location, URL(string: "http://192.168.1.20:47365/zone-1.xml"))
        XCTAssertEqual(devices[0].type, "urn:schemas-upnp-org:device:MediaRenderer:1")
    }

    func testParsesZonesRoomsAndRenderers() throws {
        let topology = try makeTopology()

        XCTAssertEqual(topology.zones.map(\.udn), ["uuid:zone-1", "uuid:zone-2"])
        let zone = topology.zones[0]
        XCTAssertEqual(zone.name, "Kitchen & Living Room")
        XCTAssertEqual(zone.location, URL(string: "http://192.168.1.20:47365/zone-1.xml"))
        XCTAssertEqual(zone.rooms.map(\.name), ["Kitchen", "Living Room"])
        XCTAssertEqual(zone.displayName, "Kitchen & Living Room")

        let living = zone.rooms[1]
        XCTAssertEqual(living.zoneUDN, "uuid:zone-1")
        XCTAssertEqual(living.powerState, "ACTIVE")
        XCTAssertEqual(living.renderers.map(\.name), ["Stereo M Left", "Stereo M Right"])
        XCTAssertEqual(living.renderers[0].location, URL(string: "http://192.168.1.32:52240/description.xml"))

        XCTAssertEqual(topology.unassignedRooms.map(\.name), ["Bathroom"])
        XCTAssertNil(topology.unassignedRooms[0].zoneUDN)
        XCTAssertTrue(topology.isComplete)
        XCTAssertEqual(topology.mediaServer?.udn, "uuid:mediaserver")
    }

    func testRoomsAreSortedZonedFirst() throws {
        XCTAssertEqual(try makeTopology().rooms.map(\.name), ["Büro", "Kitchen", "Living Room", "Bathroom"])
    }

    func testIncompleteWhenDevicesMissing() throws {
        let topology = try Topology.parse(zones: Fixture.data("getZones"), devices: [])
        XCTAssertFalse(topology.isComplete)
        XCTAssertNil(topology.zones[0].location)
        XCTAssertEqual(topology.zones[0].rooms[0].renderers[0].name, "Speaker M")
    }

    func testRoomLookupByName() throws {
        let topology = try makeTopology()
        XCTAssertEqual(topology.room(named: "kitchen")?.udn, "uuid:room-kitchen")
        XCTAssertEqual(topology.room(named: "buro")?.udn, "uuid:room-office", "diacritic-insensitive")
        XCTAssertEqual(topology.room(named: "Living")?.udn, "uuid:room-living", "prefix")
        XCTAssertEqual(topology.room(named: "room")?.udn, "uuid:room-living", "substring")
        XCTAssertNil(topology.room(named: "Garage"))
        XCTAssertNil(topology.room(named: "  "))
    }

    func testZoneLookup() throws {
        let topology = try makeTopology()
        let bath = topology.room(named: "Bathroom")!
        XCTAssertNil(topology.zone(containing: bath))
        XCTAssertEqual(topology.zone(named: "Kitchen")?.udn, "uuid:zone-1", "by room name")
        XCTAssertEqual(topology.zone(named: "Büro")?.udn, "uuid:zone-2")
    }

    func testDeviceDescriptionResolvesControlURLs() throws {
        let location = URL(string: "http://192.168.1.20:47365/zone-1.xml")!
        let description = try DeviceDescription.parse(Fixture.data("zoneDescription"), location: location)
        XCTAssertEqual(
            description.controlURLs[UPnPService.renderingControl.rawValue],
            URL(string: "http://192.168.1.20:47365/zone-1/RenderingControl/control")
        )
        XCTAssertEqual(
            description.controlURLs[UPnPService.avTransport.rawValue],
            URL(string: "http://192.168.1.20:47365/zone-1/AVTransport/control"),
            "relative paths resolve against the description URL"
        )
    }

    func testFallbackControlURL() {
        let url = ServiceResolver.fallbackURL(for: .renderingControl, kind: .renderer, location: URL(string: "http://10.0.0.5:52240/description.xml")!)
        XCTAssertEqual(url, URL(string: "http://10.0.0.5:52240/RenderingControl/ctrl"))
    }

    func testTrackMetadata() {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
        <item id="1" parentID="0" restricted="1">
        <dc:title>So What</dc:title><upnp:artist>Miles Davis</upnp:artist><upnp:album>Kind of Blue</upnp:album>
        <upnp:albumArtURI>http://example.com/cover.jpg</upnp:albumArtURI>
        <upnp:class>object.item.audioItem.musicTrack</upnp:class>
        </item></DIDL-Lite>
        """
        let metadata = TrackMetadata(didl: didl)
        XCTAssertEqual(metadata?.title, "So What")
        XCTAssertEqual(metadata?.artist, "Miles Davis")
        XCTAssertEqual(metadata?.album, "Kind of Blue")
        XCTAssertEqual(metadata?.albumArtURL, URL(string: "http://example.com/cover.jpg"))
        XCTAssertEqual(metadata?.summary, "So What — Miles Davis")

        XCTAssertNil(TrackMetadata(didl: ""))
        XCTAssertNil(TrackMetadata(didl: "NOT_IMPLEMENTED"))
        XCTAssertNil(TrackMetadata(didl: "<broken"))
    }

    func testSSDPLocationHeaderIsCaseInsensitive() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLOCATION: http://192.168.1.20:47365/config.xml\r\nST: \(SSDPDiscovery.searchTarget)\r\n\r\n"
        XCTAssertEqual(SSDPDiscovery.host(fromResponse: response), "192.168.1.20")
        XCTAssertEqual(SSDPDiscovery.host(fromResponse: "Location: http://10.0.0.2:47365/x\r\n"), "10.0.0.2")
        XCTAssertNil(SSDPDiscovery.host(fromResponse: "ST: foo\r\n"))
    }
}
