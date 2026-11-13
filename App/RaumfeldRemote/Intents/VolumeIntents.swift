import AppIntents
import RaumfeldKit

struct SetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Volume"
    static var description = IntentDescription("Sets the volume of a Raumfeld room.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Volume", description: "0 to 100", inclusiveRange: (0, 100))
    var volume: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set the volume of \(\.$room) to \(\.$volume)")
    }

    init() {}

    init(room: RoomEntity, volume: Int) {
        self.room = room
        self.volume = volume
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await RaumfeldService.shared.controller(forRoom: room.id)
        try await controller.setVolume(volume)
        return .result(dialog: "\(room.name) is at \(volume) percent.")
    }
}

enum VolumeDirection: String, AppEnum {
    case up
    case down

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Direction"
    static var caseDisplayRepresentations: [VolumeDirection: DisplayRepresentation] = [
        .up: "Up",
        .down: "Down",
    ]
}

struct ChangeVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Change Volume"
    static var description = IntentDescription("Turns the volume of a Raumfeld room up or down.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Direction", default: .up)
    var direction: VolumeDirection

    @Parameter(title: "Step", default: 5, inclusiveRange: (1, 100))
    var step: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$room) \(\.$direction) by \(\.$step)")
    }

    init() {}

    init(direction: VolumeDirection) {
        self.direction = direction
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let controller = try await RaumfeldService.shared.controller(forRoom: room.id)
        let newVolume = try await controller.adjustVolume(by: direction == .up ? step : -step)
        return .result(value: newVolume, dialog: "\(room.name) is at \(newVolume) percent.")
    }
}

struct GetVolumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Volume"
    static var description = IntentDescription("Returns the current volume of a Raumfeld room (0–100).")

    @Parameter(title: "Room")
    var room: RoomEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get the volume of \(\.$room)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let controller = try await RaumfeldService.shared.controller(forRoom: room.id)
        let volume = try await controller.volume()
        return .result(value: volume, dialog: "\(room.name) is at \(volume) percent.")
    }
}

struct SetMuteIntent: AppIntent {
    static var title: LocalizedStringResource = "Mute or Unmute"
    static var description = IntentDescription("Mutes or unmutes a Raumfeld room.")

    @Parameter(title: "Room")
    var room: RoomEntity

    @Parameter(title: "Muted", default: true)
    var muted: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set mute of \(\.$room) to \(\.$muted)")
    }

    init() {}

    init(muted: Bool) {
        self.muted = muted
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = try await RaumfeldService.shared.controller(forRoom: room.id)
        try await controller.setMuted(muted)
        return .result(dialog: muted ? "Muted \(room.name)." : "Unmuted \(room.name).")
    }
}
