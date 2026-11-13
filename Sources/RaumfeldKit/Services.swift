import Foundation

/// UPnP instance ID. The UPnP spec (and Raumfeld's own apps) use 0.
let instanceID = "0"

/// Wrapper for the UPnP RenderingControl service (volume and mute).
///
/// On a zone's virtual renderer the Raumfeld-specific `*RoomVolume` /
/// `*RoomMute` actions control a single room within the zone.
public struct RenderingControl: Sendable {
    public let soap: SOAPService

    public init(soap: SOAPService) {
        self.soap = soap
    }

    public func volume() async throws -> Int {
        let result = try await soap.call("GetVolume", [("InstanceID", instanceID), ("Channel", "Master")])
        return try Self.int(result["CurrentVolume"], action: "GetVolume")
    }

    public func setVolume(_ volume: Int) async throws {
        try await soap.call("SetVolume", [
            ("InstanceID", instanceID), ("Channel", "Master"), ("DesiredVolume", String(clampVolume(volume))),
        ])
    }

    /// Raumfeld extension: relative volume change on a renderer.
    public func changeVolume(by amount: Int) async throws {
        try await soap.call("ChangeVolume", [("InstanceID", instanceID), ("Amount", String(amount))])
    }

    public func isMuted() async throws -> Bool {
        let result = try await soap.call("GetMute", [("InstanceID", instanceID), ("Channel", "Master")])
        return Self.bool(result["CurrentMute"])
    }

    public func setMuted(_ muted: Bool) async throws {
        try await soap.call("SetMute", [
            ("InstanceID", instanceID), ("Channel", "Master"), ("DesiredMute", muted ? "1" : "0"),
        ])
    }

    // MARK: Raumfeld per-room actions (virtual zone renderer only)

    public func roomVolume(roomUDN: String) async throws -> Int {
        let result = try await soap.call("GetRoomVolume", [("InstanceID", instanceID), ("Room", roomUDN)])
        return try Self.int(result["CurrentVolume"], action: "GetRoomVolume")
    }

    public func setRoomVolume(roomUDN: String, _ volume: Int) async throws {
        try await soap.call("SetRoomVolume", [
            ("InstanceID", instanceID), ("Room", roomUDN), ("DesiredVolume", String(clampVolume(volume))),
        ])
    }

    public func isRoomMuted(roomUDN: String) async throws -> Bool {
        let result = try await soap.call("GetRoomMute", [("InstanceID", instanceID), ("Room", roomUDN)])
        return Self.bool(result["CurrentMute"])
    }

    public func setRoomMuted(roomUDN: String, _ muted: Bool) async throws {
        try await soap.call("SetRoomMute", [
            ("InstanceID", instanceID), ("Room", roomUDN), ("DesiredMute", muted ? "1" : "0"),
        ])
    }

    static func int(_ value: String?, action: String) throws -> Int {
        guard let value, let number = Int(value.trimmingCharacters(in: .whitespaces)) else {
            throw RaumfeldError.invalidResponse("\(action) returned \(value ?? "nothing")")
        }
        return number
    }

    static func bool(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }
}

func clampVolume(_ volume: Int) -> Int {
    min(100, max(0, volume))
}

/// Playback state reported by `GetTransportInfo`.
public enum TransportState: String, Sendable {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMediaPresent = "NO_MEDIA_PRESENT"
    case unknown

    public init(upnp value: String) {
        self = TransportState(rawValue: value.trimmingCharacters(in: .whitespaces)) ?? .unknown
    }

    public var isPlaying: Bool {
        self == .playing || self == .transitioning
    }
}

public struct PositionInfo: Sendable, Hashable {
    public var track: Int?
    public var trackDuration: String
    public var relativeTime: String
    public var trackURI: String
    /// Parsed DIDL-Lite metadata of the current track, if any.
    public var metadata: TrackMetadata?
}

public struct MediaInfo: Sendable, Hashable {
    public var numberOfTracks: Int?
    public var currentURI: String
    /// Parsed DIDL-Lite metadata of the current URI (e.g. a radio station or playlist).
    public var metadata: TrackMetadata?
}

/// Seek target units understood by `AVTransport.seek`.
public enum SeekUnit: String, Sendable {
    case absoluteTime = "ABS_TIME"
    case relativeTime = "REL_TIME"
    case trackNumber = "TRACK_NR"
}

/// Wrapper for the UPnP AVTransport service (playback).
public struct AVTransport: Sendable {
    public let soap: SOAPService

    public init(soap: SOAPService) {
        self.soap = soap
    }

    public func play() async throws {
        try await soap.call("Play", [("InstanceID", instanceID), ("Speed", "1")])
    }

    public func pause() async throws {
        try await soap.call("Pause", [("InstanceID", instanceID)])
    }

    public func stop() async throws {
        try await soap.call("Stop", [("InstanceID", instanceID)])
    }

    public func next() async throws {
        try await soap.call("Next", [("InstanceID", instanceID)])
    }

    public func previous() async throws {
        try await soap.call("Previous", [("InstanceID", instanceID)])
    }

    public func seek(to target: String, unit: SeekUnit = .absoluteTime) async throws {
        try await soap.call("Seek", [("InstanceID", instanceID), ("Unit", unit.rawValue), ("Target", target)])
    }

    /// Replaces what the renderer plays and starts playback.
    public func play(uri: String, metadata: String = "") async throws {
        try await setURI(uri, metadata: metadata)
        try await play()
    }

    public func setURI(_ uri: String, metadata: String = "") async throws {
        try await soap.call("SetAVTransportURI", [
            ("InstanceID", instanceID), ("CurrentURI", uri), ("CurrentURIMetaData", metadata),
        ])
    }

    /// Raumfeld extension: switch the source without interrupting a running queue.
    public func bend(uri: String, metadata: String = "") async throws {
        try await soap.call("BendAVTransportURI", [
            ("InstanceID", instanceID), ("CurrentURI", uri), ("CurrentURIMetaData", metadata),
        ])
    }

    public func transportState() async throws -> TransportState {
        let result = try await soap.call("GetTransportInfo", [("InstanceID", instanceID)])
        return TransportState(upnp: result["CurrentTransportState"] ?? "")
    }

    public func positionInfo() async throws -> PositionInfo {
        let result = try await soap.call("GetPositionInfo", [("InstanceID", instanceID)])
        return PositionInfo(
            track: result["Track"].flatMap { Int($0) },
            trackDuration: result["TrackDuration"] ?? "",
            relativeTime: result["RelTime"] ?? "",
            trackURI: result["TrackURI"] ?? "",
            metadata: result["TrackMetaData"].flatMap(TrackMetadata.init(didl:))
        )
    }

    public func mediaInfo() async throws -> MediaInfo {
        let result = try await soap.call("GetMediaInfo", [("InstanceID", instanceID)])
        return MediaInfo(
            numberOfTracks: result["NrTracks"].flatMap { Int($0) },
            currentURI: result["CurrentURI"] ?? "",
            metadata: result["CurrentURIMetaData"].flatMap(TrackMetadata.init(didl:))
        )
    }
}

/// Wrapper for the UPnP ContentDirectory service on the Raumfeld media server.
public struct ContentDirectory: Sendable {
    public let soap: SOAPService

    public init(soap: SOAPService) {
        self.soap = soap
    }

    public struct BrowseResult: Sendable, Hashable {
        /// Raw DIDL-Lite XML.
        public var didl: String
        public var numberReturned: Int
        public var totalMatches: Int
    }

    public func browse(
        objectID: String,
        directChildren: Bool = true,
        filter: String = "*",
        start: Int = 0,
        count: Int = 25,
        sort: String = ""
    ) async throws -> BrowseResult {
        let result = try await soap.call("Browse", [
            ("ObjectID", objectID),
            ("BrowseFlag", directChildren ? "BrowseDirectChildren" : "BrowseMetadata"),
            ("Filter", filter),
            ("StartingIndex", String(start)),
            ("RequestedCount", String(count)),
            ("SortCriteria", sort),
        ])
        return Self.browseResult(result)
    }

    public func search(
        containerID: String,
        criteria: String,
        filter: String = "*",
        start: Int = 0,
        count: Int = 25,
        sort: String = ""
    ) async throws -> BrowseResult {
        let result = try await soap.call("Search", [
            ("ContainerID", containerID),
            ("SearchCriteria", criteria),
            ("Filter", filter),
            ("StartingIndex", String(start)),
            ("RequestedCount", String(count)),
            ("SortCriteria", sort),
        ])
        return Self.browseResult(result)
    }

    @discardableResult
    public func createQueue(desiredName: String, containerID: String) async throws -> (name: String, queueID: String) {
        let result = try await soap.call("CreateQueue", [("DesiredName", desiredName), ("ContainerID", containerID)])
        return (result["GivenName"] ?? desiredName, result["QueueID"] ?? "")
    }

    public func addContainer(
        queueID: String,
        containerID: String,
        sourceID: String = "",
        criteria: String = "",
        startIndex: Int = 0,
        endIndex: Int = 0,
        position: Int = 0
    ) async throws {
        try await soap.call("AddContainerToQueue", [
            ("QueueID", queueID), ("ContainerID", containerID), ("SourceID", sourceID),
            ("SearchCriteria", criteria), ("StartIndex", String(startIndex)),
            ("EndIndex", String(endIndex)), ("Position", String(position)),
        ])
    }

    public func addItem(queueID: String, objectID: String, position: Int) async throws {
        try await soap.call("AddItemToQueue", [
            ("QueueID", queueID), ("ObjectID", objectID), ("Position", String(position)),
        ])
    }

    public func moveInQueue(objectID: String, newPosition: Int) async throws {
        try await soap.call("MoveInQueue", [("ObjectID", objectID), ("NewPosition", String(newPosition))])
    }

    public func removeFromQueue(queueID: String, from: Int, to: Int) async throws {
        try await soap.call("RemoveFromQueue", [
            ("QueueID", queueID), ("FromPosition", String(from)), ("ToPosition", String(to)),
        ])
    }

    static func browseResult(_ result: [String: String]) -> BrowseResult {
        BrowseResult(
            didl: result["Result"] ?? "",
            numberReturned: result["NumberReturned"].flatMap { Int($0) } ?? 0,
            totalMatches: result["TotalMatches"].flatMap { Int($0) } ?? 0
        )
    }
}
