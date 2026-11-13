import Foundation
import RaumfeldKit

// A small command-line tool for trying RaumfeldKit against a real system.
//
//   swift run raumfeld [--host <ip>] <command> [arguments]

let usage = """
Usage: raumfeld [--host <ip>] <command> [arguments]

Without --host (or the RAUMFELD_HOST environment variable) the host is found via SSDP.

Commands:
  discover                     Print the IP address of the Raumfeld host
  rooms                        List zones, rooms and speakers
  volume <room>                Print a room's volume
  volume <room> <0-100>        Set a room's volume
  volume <room> +5 | -5        Change a room's volume
  zone-volume <room> [value]   Get/set the volume of the room's whole zone
  mute <room> [on|off]         Toggle or set mute
  play | pause | toggle | stop | next | previous <room>
  now <room>                   Show what is playing
  join <room> <other room>     Put <room> into the zone of <other room>
  leave <room>                 Remove <room> from its zone
  watch                        Print the topology whenever it changes
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let (host, command, rest): (String?, String, [String]) = {
    var arguments = Array(CommandLine.arguments.dropFirst())
    var host = ProcessInfo.processInfo.environment["RAUMFELD_HOST"]
    if let index = arguments.firstIndex(of: "--host") {
        guard index + 1 < arguments.count else { fail(usage) }
        host = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
    }
    guard let command = arguments.first else { fail(usage) }
    return (host, command, Array(arguments.dropFirst()))
}()

func makeClient() async throws -> RaumfeldClient {
    if let host { return RaumfeldClient(host: host) }
    return try await RaumfeldClient.discover()
}

func printTopology(_ topology: Topology) {
    for zone in topology.zones {
        print("Zone \(zone.displayName)  [\(zone.udn)]")
        for room in zone.rooms {
            print("  \(room.name)  [\(room.udn)] \(room.powerState ?? "")")
            for renderer in room.renderers {
                print("    \(renderer.name)  \(renderer.location?.host ?? "?")")
            }
        }
    }
    if !topology.unassignedRooms.isEmpty {
        print("Unassigned")
        for room in topology.unassignedRooms {
            print("  \(room.name)  [\(room.udn)] \(room.powerState ?? "")")
        }
    }
}

func run() async throws {
    if command == "discover" {
        guard let found = try await SSDPDiscovery.findHost() else { throw RaumfeldError.hostNotFound }
        print(found)
        return
    }

    let client = try await makeClient()

    if command == "watch" {
        for await topology in client.topologyUpdates() {
            print("--- \(Date())")
            printTopology(topology)
        }
        return
    }

    let topology = try await client.fetchTopology()

    func room(at index: Int) throws -> RoomController {
        guard index < rest.count else { fail(usage) }
        return try client.room(named: rest[index], in: topology)
    }

    switch command {
    case "rooms":
        printTopology(topology)

    case "volume":
        let controller = try room(at: 0)
        if rest.count > 1 {
            let value = rest[1]
            if value.hasPrefix("+") || value.hasPrefix("-"), let delta = Int(value) {
                print(try await controller.adjustVolume(by: delta))
            } else if let volume = Int(value) {
                try await controller.setVolume(volume)
                print(volume)
            } else {
                fail("Invalid volume: \(value)")
            }
        } else {
            print(try await controller.volume())
        }

    case "zone-volume":
        guard let zone = try room(at: 0).zone else { fail("\(rest[0]) is not in a zone") }
        let controller = client.controller(for: zone)
        if rest.count > 1, let volume = Int(rest[1]) {
            try await controller.setVolume(volume)
        }
        print(try await controller.volume())

    case "mute":
        let controller = try room(at: 0)
        switch rest.count > 1 ? rest[1] : nil {
        case "on": try await controller.setMuted(true); print("muted")
        case "off": try await controller.setMuted(false); print("unmuted")
        default: print(try await controller.toggleMute() ? "muted" : "unmuted")
        }

    case "play": try await room(at: 0).play()
    case "pause": try await room(at: 0).pause()
    case "stop": try await room(at: 0).stop()
    case "next": try await room(at: 0).next()
    case "previous": try await room(at: 0).previous()
    case "toggle": print(try await room(at: 0).togglePlayPause().rawValue)

    case "now":
        let nowPlaying = try await room(at: 0).nowPlaying()
        print("\(nowPlaying.state.rawValue): \(nowPlaying.summary ?? "–")")
        if let source = nowPlaying.source?.summary { print("Source: \(source)") }
        if let position = nowPlaying.position, let duration = nowPlaying.duration {
            print("\(position) / \(duration)")
        }

    case "join":
        let moving = try room(at: 0).room
        guard let target = try room(at: 1).zone else { fail("\(rest[1]) is not in a zone") }
        try await client.connect(room: moving.udn, toZone: target.udn)

    case "leave":
        try await client.drop(room: try room(at: 0).room.udn)

    default:
        fail(usage)
    }
}

do {
    try await run()
} catch {
    fail("Error: \(error.localizedDescription)")
}
