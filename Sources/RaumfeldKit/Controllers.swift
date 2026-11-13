import Foundation

/// What is playing in a room or zone.
public struct NowPlaying: Sendable, Hashable {
    public var state: TransportState
    /// The current track (from `GetPositionInfo`).
    public var track: TrackMetadata?
    /// The current source, e.g. a radio station or playlist (from `GetMediaInfo`).
    public var source: TrackMetadata?
    public var position: String?
    public var duration: String?

    /// Best available one-line description.
    public var summary: String? {
        track?.summary ?? source?.summary
    }
}

/// Controls a single room.
///
/// Volume and mute affect only this room. Playback commands (play, pause, next…)
/// affect the zone the room belongs to, because a zone has a single playback queue.
public struct RoomController: Sendable {
    public let room: Room
    /// The zone the room is in, or `nil` if the room is unassigned.
    public let zone: Zone?
    let client: RaumfeldClient

    init(client: RaumfeldClient, room: Room, zone: Zone?) {
        self.client = client
        self.room = room
        self.zone = zone
    }

    // MARK: Volume

    /// Current volume of the room, 0–100.
    public func volume() async throws -> Int {
        try await withRoomRendering(
            zone: { try await $0.roomVolume(roomUDN: room.udn) },
            renderer: { try await $0.volume() }
        )
    }

    /// Sets the room's volume (clamped to 0–100).
    public func setVolume(_ volume: Int) async throws {
        try await withRoomRendering(
            zone: { try await $0.setRoomVolume(roomUDN: room.udn, volume) },
            renderer: { try await $0.setVolume(volume) }
        )
    }

    /// Changes the volume by `delta` (e.g. `+5` or `-10`) and returns the new volume.
    @discardableResult
    public func adjustVolume(by delta: Int) async throws -> Int {
        let target = clampVolume(try await volume() + delta)
        try await setVolume(target)
        return target
    }

    public func isMuted() async throws -> Bool {
        try await withRoomRendering(
            zone: { try await $0.isRoomMuted(roomUDN: room.udn) },
            renderer: { try await $0.isMuted() }
        )
    }

    public func setMuted(_ muted: Bool) async throws {
        try await withRoomRendering(
            zone: { try await $0.setRoomMuted(roomUDN: room.udn, muted) },
            renderer: { try await $0.setMuted(muted) }
        )
    }

    /// Toggles mute and returns the new state.
    @discardableResult
    public func toggleMute() async throws -> Bool {
        let muted = try await !isMuted()
        try await setMuted(muted)
        return muted
    }

    /// Runs a volume/mute operation for this room.
    ///
    /// If the room is in a zone, the zone's virtual renderer is asked first
    /// using the Raumfeld per-room actions (`SetRoomVolume`, …). That keeps the
    /// zone's overall volume in sync. If that fails with a SOAP fault (or the room
    /// is unassigned), the room's own speaker is controlled directly instead,
    /// which is what the original Python library always did.
    private func withRoomRendering<T: Sendable>(
        zone zoneOperation: (RenderingControl) async throws -> T,
        renderer rendererOperation: (RenderingControl) async throws -> T
    ) async throws -> T {
        if let zoneLocation = zone?.location {
            do {
                return try await zoneOperation(await client.renderingControl(at: zoneLocation, kind: .zone))
            } catch RaumfeldError.soapFault where firstRendererLocation != nil {
                // Fall through to the physical renderer.
            }
        }
        guard let location = firstRendererLocation else {
            throw RaumfeldError.notFound("A speaker for room \"\(room.name)\"")
        }
        return try await rendererOperation(await client.renderingControl(at: location))
    }

    private var firstRendererLocation: URL? {
        room.renderers.lazy.compactMap(\.location).first
    }

    // MARK: Playback

    /// The AVTransport of the room's zone, or of its own speaker if unassigned.
    public func transport() async throws -> AVTransport {
        if let zoneLocation = zone?.location {
            return await client.avTransport(at: zoneLocation, kind: .zone)
        }
        guard let location = firstRendererLocation else {
            throw RaumfeldError.notFound("A renderer for room \"\(room.name)\"")
        }
        return await client.avTransport(at: location, kind: .renderer)
    }

    public func play() async throws { try await transport().play() }
    public func pause() async throws { try await transport().pause() }
    public func stop() async throws { try await transport().stop() }
    public func next() async throws { try await transport().next() }
    public func previous() async throws { try await transport().previous() }

    /// Pauses if playing, otherwise starts playback. Returns the new state.
    @discardableResult
    public func togglePlayPause() async throws -> TransportState {
        try await RaumfeldKit.togglePlayPause(try await transport())
    }

    public func nowPlaying() async throws -> NowPlaying {
        try await RaumfeldKit.nowPlaying(try await transport())
    }
}

/// Controls a whole zone through its virtual renderer.
public struct ZoneController: Sendable {
    public let zone: Zone
    let client: RaumfeldClient

    init(client: RaumfeldClient, zone: Zone) {
        self.client = client
        self.zone = zone
    }

    private func location() throws -> URL {
        guard let location = zone.location else { throw RaumfeldError.notFound("Zone renderer \(zone.udn)") }
        return location
    }

    public func renderingControl() async throws -> RenderingControl {
        await client.renderingControl(at: try location(), kind: .zone)
    }

    public func transport() async throws -> AVTransport {
        await client.avTransport(at: try location(), kind: .zone)
    }

    /// Zone volume, 0–100. Changing it scales all rooms of the zone proportionally.
    public func volume() async throws -> Int { try await renderingControl().volume() }
    public func setVolume(_ volume: Int) async throws { try await renderingControl().setVolume(volume) }

    @discardableResult
    public func adjustVolume(by delta: Int) async throws -> Int {
        let control = try await renderingControl()
        let target = clampVolume(try await control.volume() + delta)
        try await control.setVolume(target)
        return target
    }

    public func isMuted() async throws -> Bool { try await renderingControl().isMuted() }
    public func setMuted(_ muted: Bool) async throws { try await renderingControl().setMuted(muted) }

    public func play() async throws { try await transport().play() }
    public func pause() async throws { try await transport().pause() }
    public func stop() async throws { try await transport().stop() }
    public func next() async throws { try await transport().next() }
    public func previous() async throws { try await transport().previous() }

    @discardableResult
    public func togglePlayPause() async throws -> TransportState {
        try await RaumfeldKit.togglePlayPause(try await transport())
    }

    public func nowPlaying() async throws -> NowPlaying {
        try await RaumfeldKit.nowPlaying(try await transport())
    }
}

func togglePlayPause(_ transport: AVTransport) async throws -> TransportState {
    if try await transport.transportState().isPlaying {
        try await transport.pause()
        return .paused
    } else {
        try await transport.play()
        return .playing
    }
}

func nowPlaying(_ transport: AVTransport) async throws -> NowPlaying {
    async let state = transport.transportState()
    async let position = transport.positionInfo()
    async let media = try? transport.mediaInfo()
    let positionInfo = try await position
    return NowPlaying(
        state: try await state,
        track: positionInfo.metadata,
        source: await media?.metadata,
        position: positionInfo.relativeTime.isEmpty ? nil : positionInfo.relativeTime,
        duration: positionInfo.trackDuration.isEmpty ? nil : positionInfo.trackDuration
    )
}
