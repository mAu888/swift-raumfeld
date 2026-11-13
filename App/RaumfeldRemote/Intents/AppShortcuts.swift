import AppIntents

/// Siri phrases that work without any setup by the user.
///
/// Every phrase must contain the app name. The room can be spoken as part of the
/// phrase ("Turn up Kitchen with Raumfeld Remote"); otherwise Siri asks for it.
/// Siri learns the room names from `RoomQuery.suggestedEntities()`, refreshed by
/// `RaumfeldShortcuts.updateAppShortcutParameters()` whenever the rooms change.
struct RaumfeldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ChangeVolumeIntent(direction: .up),
            phrases: [
                "Turn up \(\.$room) with \(.applicationName)",
                "Louder in \(\.$room) with \(.applicationName)",
                "Turn up \(.applicationName)",
            ],
            shortTitle: "Volume Up",
            systemImageName: "speaker.wave.3"
        )
        AppShortcut(
            intent: ChangeVolumeIntent(direction: .down),
            phrases: [
                "Turn down \(\.$room) with \(.applicationName)",
                "Quieter in \(\.$room) with \(.applicationName)",
                "Turn down \(.applicationName)",
            ],
            shortTitle: "Volume Down",
            systemImageName: "speaker.wave.1"
        )
        AppShortcut(
            intent: SetVolumeIntent(),
            phrases: [
                "Set the volume in \(\.$room) with \(.applicationName)",
                "Set \(.applicationName) volume",
            ],
            shortTitle: "Set Volume",
            systemImageName: "slider.horizontal.3"
        )
        AppShortcut(
            intent: SetMuteIntent(muted: true),
            phrases: [
                "Mute \(\.$room) with \(.applicationName)",
                "Mute \(.applicationName)",
            ],
            shortTitle: "Mute",
            systemImageName: "speaker.slash"
        )
        AppShortcut(
            intent: SetMuteIntent(muted: false),
            phrases: [
                "Unmute \(\.$room) with \(.applicationName)",
                "Unmute \(.applicationName)",
            ],
            shortTitle: "Unmute",
            systemImageName: "speaker.wave.2"
        )
        AppShortcut(
            intent: PlaybackIntent(command: .pause),
            phrases: [
                "Pause \(\.$room) with \(.applicationName)",
                "Pause \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause"
        )
        AppShortcut(
            intent: PlaybackIntent(command: .play),
            phrases: [
                "Resume \(\.$room) with \(.applicationName)",
                "Play \(\.$room) with \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Play",
            systemImageName: "play"
        )
        AppShortcut(
            intent: PlaybackIntent(command: .next),
            phrases: [
                "Next track in \(\.$room) with \(.applicationName)",
                "Skip \(.applicationName)",
            ],
            shortTitle: "Next Track",
            systemImageName: "forward"
        )
        AppShortcut(
            intent: NowPlayingIntent(),
            phrases: [
                "What's playing in \(\.$room) on \(.applicationName)",
                "What's playing on \(.applicationName)",
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.note"
        )
    }
}
