import Foundation

/// A UPnP device announced by the Raumfeld host (`listDevices`).
public struct Device: Sendable, Hashable, Identifiable {
    public var udn: String
    public var name: String
    public var location: URL
    public var type: String?

    public var id: String { udn }

    public init(udn: String, name: String, location: URL, type: String? = nil) {
        self.udn = udn
        self.name = name
        self.location = location
        self.type = type
    }
}

/// A physical speaker (or other playback device).
public struct Renderer: Sendable, Hashable, Identifiable {
    public var udn: String
    public var name: String
    /// URL of the device description. `nil` if the device is not (yet) listed by the host.
    public var location: URL?

    public var id: String { udn }

    public init(udn: String, name: String, location: URL?) {
        self.udn = udn
        self.name = name
        self.location = location
    }
}

/// A room, containing one or more renderers.
public struct Room: Sendable, Hashable, Identifiable {
    public var udn: String
    public var name: String
    public var renderers: [Renderer]
    /// UDN of the zone this room belongs to, or `nil` if it is unassigned.
    public var zoneUDN: String?
    /// e.g. `ACTIVE`, `MANUAL_STANDBY`, `AUTOMATIC_STANDBY`.
    public var powerState: String?

    public var id: String { udn }

    public init(udn: String, name: String, renderers: [Renderer], zoneUDN: String?, powerState: String? = nil) {
        self.udn = udn
        self.name = name
        self.renderers = renderers
        self.zoneUDN = zoneUDN
        self.powerState = powerState
    }
}

/// A zone: a group of rooms playing the same audio through one virtual renderer.
public struct Zone: Sendable, Hashable, Identifiable {
    public var udn: String
    /// Name of the zone's virtual renderer as announced by the host.
    public var name: String
    /// Location of the zone's virtual renderer. `nil` if not (yet) listed by the host.
    public var location: URL?
    public var rooms: [Room]

    public var id: String { udn }

    /// A readable name, e.g. "Kitchen & Living Room".
    public var displayName: String {
        let roomNames = rooms.map(\.name)
        return roomNames.isEmpty ? name : roomNames.joined(separator: " & ")
    }

    public init(udn: String, name: String, location: URL?, rooms: [Room]) {
        self.udn = udn
        self.name = name
        self.location = location
        self.rooms = rooms
    }
}

/// A snapshot of the whole Raumfeld system: zones, rooms, renderers and devices.
public struct Topology: Sendable, Hashable {
    public var zones: [Zone]
    public var unassignedRooms: [Room]
    public var devices: [Device]

    public init(zones: [Zone] = [], unassignedRooms: [Room] = [], devices: [Device] = []) {
        self.zones = zones
        self.unassignedRooms = unassignedRooms
        self.devices = devices
    }

    /// All rooms, zoned ones first, sorted by name within each group.
    public var rooms: [Room] {
        zones.flatMap(\.rooms).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            + unassignedRooms.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The Raumfeld media server (used for browsing and queues).
    public var mediaServer: Device? {
        devices.first { $0.name == "Raumfeld MediaServer" }
            ?? devices.first { $0.type?.contains("MediaServer") == true }
    }

    /// True when every zone and renderer has a matching device entry. Right after
    /// a configuration change the host may report rooms before their devices.
    public var isComplete: Bool {
        zones.allSatisfy { zone in
            zone.location != nil && zone.rooms.allSatisfy { $0.renderers.allSatisfy { $0.location != nil } }
        } && unassignedRooms.allSatisfy { $0.renderers.allSatisfy { $0.location != nil } }
    }

    public func room(udn: String) -> Room? {
        rooms.first { $0.udn == udn }
    }

    public func zone(udn: String) -> Zone? {
        zones.first { $0.udn == udn }
    }

    public func zone(containing room: Room) -> Zone? {
        zones.first { zone in zone.rooms.contains { $0.udn == room.udn } }
    }

    /// Finds a room by name: an exact (case/diacritic-insensitive) match first,
    /// then a prefix match, then a substring match.
    public func room(named name: String) -> Room? {
        Self.bestMatch(for: name, in: rooms, name: \.name)
    }

    /// Finds a zone by the name of its virtual renderer or one of its rooms.
    public func zone(named name: String) -> Zone? {
        if let zone = Self.bestMatch(for: name, in: zones, name: \.name) { return zone }
        return room(named: name).flatMap { zone(containing: $0) }
    }

    static func bestMatch<T>(for query: String, in items: [T], name: KeyPath<T, String>) -> T? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        if let exact = items.first(where: { $0[keyPath: name].compare(needle, options: options) == .orderedSame }) {
            return exact
        }
        if let prefix = items.first(where: { $0[keyPath: name].range(of: needle, options: options.union(.anchored)) != nil }) {
            return prefix
        }
        return items.first { $0[keyPath: name].range(of: needle, options: options) != nil }
    }
}

// MARK: - Parsing

extension Topology {
    /// Parses the body of the host's `listDevices` endpoint.
    ///
    /// ```xml
    /// <devices>
    ///   <device udn="uuid:…" location="http://…/description.xml" type="urn:…">Kitchen</device>
    /// </devices>
    /// ```
    public static func parseDevices(_ data: Data) throws -> [Device] {
        let root = try XElement.parse(data)
        return root.all("device").compactMap { element in
            guard
                let udn = element["udn"],
                let locationString = element["location"],
                let location = URL(string: locationString)
            else { return nil }
            return Device(
                udn: udn,
                name: element.text.trimmingCharacters(in: .whitespacesAndNewlines),
                location: location,
                type: element["type"]
            )
        }
    }

    /// Builds a topology from the bodies of `getZones` and `listDevices`.
    ///
    /// ```xml
    /// <zoneConfig>
    ///   <zones>
    ///     <zone udn="uuid:…">
    ///       <room udn="uuid:…" name="Kitchen" powerState="ACTIVE">
    ///         <renderer udn="uuid:…" name="Speaker M"/>
    ///       </room>
    ///     </zone>
    ///   </zones>
    ///   <unassignedRooms>
    ///     <room udn="uuid:…" name="Bath"><renderer udn="uuid:…" name="One M"/></room>
    ///   </unassignedRooms>
    /// </zoneConfig>
    /// ```
    public static func parse(zones zoneData: Data, devices: [Device]) throws -> Topology {
        let root = try XElement.parse(zoneData)
        let devicesByUDN = Dictionary(devices.map { ($0.udn, $0) }, uniquingKeysWith: { first, _ in first })

        func parseRoom(_ element: XElement, zoneUDN: String?) -> Room? {
            guard let udn = element["udn"] else { return nil }
            let renderers = element.all("renderer").compactMap { rendererElement -> Renderer? in
                guard let rendererUDN = rendererElement["udn"] else { return nil }
                return Renderer(
                    udn: rendererUDN,
                    name: rendererElement["name"] ?? devicesByUDN[rendererUDN]?.name ?? "",
                    location: devicesByUDN[rendererUDN]?.location
                )
            }
            return Room(
                udn: udn,
                name: element["name"] ?? "",
                renderers: renderers,
                zoneUDN: zoneUDN,
                powerState: element["powerState"]
            )
        }

        let zones = root.all("zone").compactMap { element -> Zone? in
            guard let udn = element["udn"] else { return nil }
            let device = devicesByUDN[udn]
            return Zone(
                udn: udn,
                name: device?.name ?? "",
                location: device?.location,
                rooms: element.all("room").compactMap { parseRoom($0, zoneUDN: udn) }
            )
        }

        let unassigned = root.first("unassignedRooms")?.all("room").compactMap { parseRoom($0, zoneUDN: nil) } ?? []

        return Topology(zones: zones, unassignedRooms: unassigned, devices: devices)
    }
}
