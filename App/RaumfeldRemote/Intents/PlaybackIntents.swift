import AppIntents
import RaumfeldKit

/// Playback commands act on the zone the room belongs to, because all rooms in
/// a zone share one queue.
enum PlaybackCommand: String, AppEnum {
    case play
    case pause
    case toggle
    case stop
    case next
    case previous

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Command"
    static var caseDisplayRepresentations: [PlaybackCommand: DisplayRepresentation] = [
        .play: "Play",
        .pause: "Pause",
        .toggle: "Play/Pause",
        .stop: "Stop",
        .next: "Next Track",
        .previous: "Previous Track",
    ]
}

struct PlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Control Playback"
    static var description = IntentDescription("Plays, pauses or skips in a Raumfeld room and every room grouped with it.")

    @Parameter(title: "Command", default: .toggle)
    var command: PlaybackCommand

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command) in \(\.$room)")
    }

    init() {}

    init(command: PlaybackCommand) {
        self.command = command
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await RaumfeldService.shared.controller(forRoom: room.id)
        switch command {
        case .play:
            try await controller.play()
            return .result(dialog: "Playing in \(room.name).")
        case .pause:
            try await controller.pause()
            return .result(dialog: "Paused \(room.name).")
        case .toggle:
            let state = try await controller.togglePlayPause()
            return .result(dialog: state.isPlaying ? "Playing in \(room.name)." : "Paused \(room.name).")
        case .stop:
            try await controller.stop()
            return .result(dialog: "Stopped \(room.name).")
        case .next:
            try await controller.next()
            return .result(dialog: "Next track.")
        case .previous:
            try await controller.previous()
            return .result(dialog: "Previous track.")
        }
    }
}

struct NowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource = "What's Playing"
    static var description = IntentDescription("Tells you what is playing in a Raumfeld room.")

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("What's playing in \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let controller = try await RaumfeldService.shared.controller(forRoom: room.id)
        let nowPlaying = try await controller.nowPlaying()
        let summary = nowPlaying.summary ?? "Nothing"
        let dialog: IntentDialog
        switch nowPlaying.state {
        case .playing, .transitioning:
            dialog = "\(summary) is playing in \(room.name)."
        case .paused:
            dialog = "\(summary) is paused in \(room.name)."
        default:
            dialog = "Nothing is playing in \(room.name)."
        }
        return .result(value: summary, dialog: dialog)
    }
}

/// Moves a room into another room's zone, e.g. "add the kitchen to the living room".
struct JoinRoomIntent: AppIntent {
    static var title: LocalizedStringResource = "Group Rooms"
    static var description = IntentDescription("Adds a room to the zone of another room so both play the same music.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Join")
    var target: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$room) to \(\.$target)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = RaumfeldService.shared
        let client = try await service.currentClient()
        let topology = try await service.topology(maxAge: 0)
        guard let movingRoom = topology.room(udn: room.id) else { throw RaumfeldError.notFound(room.name) }
        guard let targetRoom = topology.room(udn: target.id) else { throw RaumfeldError.notFound(target.name) }

        if let zone = topology.zone(containing: targetRoom) {
            try await client.connect(room: movingRoom.udn, toZone: zone.udn)
        } else if let zone = topology.zone(containing: movingRoom) {
            // The target is unassigned: pull it into the moving room's zone instead.
            try await client.connect(room: targetRoom.udn, toZone: zone.udn)
        } else {
            // Neither room is in a zone: create one for the target, wait for it, then join.
            try await client.connect(room: targetRoom.udn)
            var newZone: Zone?
            for _ in 0..<10 where newZone == nil {
                try await Task.sleep(nanoseconds: 500_000_000)
                newZone = try await service.topology(maxAge: 0).zone(containing: targetRoom)
            }
            guard let newZone else { throw RaumfeldError.notFound("The new zone") }
            try await client.connect(room: movingRoom.udn, toZone: newZone.udn)
        }
        return .result(dialog: "\(room.name) now plays with \(target.name).")
    }
}

struct LeaveZoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Ungroup Room"
    static var description = IntentDescription("Removes a room from its zone.")

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$room) from its group")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await RaumfeldService.shared.currentClient().drop(room: room.id)
        return .result(dialog: "\(room.name) is no longer grouped.")
    }
}
