# swift-raumfeld

Control Teufel Raumfeld speakers from Swift, plus an iOS app with Siri and Shortcuts support.

This is a Swift port of [PyRaumfeld](https://github.com/maierp/pyraumfeld). The original
Python library is still here (see [PyRaumfeld](#pyraumfeld-05) below) as a reference.

| Part | What it is |
|---|---|
| `Sources/RaumfeldKit` | Swift package with no dependencies: zones, rooms, speakers, volume, mute, playback, grouping, media server, live updates |
| `Sources/raumfeld-cli` | `raumfeld` command-line tool for trying the library against your system |
| `App/` | iOS 17 app *Raumfeld Remote*: room list with volume sliders, App Intents, Siri phrases |

## RaumfeldKit

```swift
import RaumfeldKit

let raumfeld = RaumfeldClient(host: "192.168.1.20")   // or: try await RaumfeldClient.discover()
let topology = try await raumfeld.fetchTopology()

let kitchen = try raumfeld.room(named: "Kitchen", in: topology)
try await kitchen.setVolume(30)            // this room only
try await kitchen.adjustVolume(by: -5)
try await kitchen.setMuted(true)
try await kitchen.togglePlayPause()        // the room's whole zone
print(try await kitchen.nowPlaying().summary ?? "–")

if let zone = kitchen.zone {
    try await raumfeld.controller(for: zone).setVolume(40)   // all rooms of the zone
}

// Group rooms
try await raumfeld.connect(room: bathroom.udn, toZone: zone.udn)
try await raumfeld.drop(room: bathroom.udn)

// Follow changes (rooms grouped, speakers switched on or off, …)
for await topology in raumfeld.topologyUpdates() {
    print(topology.zones.map(\.displayName))
}
```

Add it to an Xcode project or `Package.swift` as a Swift package: iOS 16+, macOS 13+, and Linux.

### How it talks to Raumfeld

* **Host web service** (port `47365`): `getZones` and `listDevices` give the
  structure. Both support long polling with an `updateID` header, which
  `topologyUpdates()` uses. `connectRoomToZone` and `dropRoomJob` group and ungroup rooms.
* **UPnP SOAP** on each renderer:
  * RenderingControl for volume and mute
  * AVTransport for playback
  * ContentDirectory on the media server for browsing and queues

  Control URLs are read from each device's description. If that fails, the paths
  the Python library hardcoded are used.
* **Room volume**: for a room in a zone, the zone's virtual renderer is asked
  using the Raumfeld `SetRoomVolume` / `GetRoomVolume` actions. If it answers
  with a SOAP fault, the room's speaker is controlled directly instead, as the
  Python library always did.
* **Discovery**: SSDP M-SEARCH for `urn:schemas-raumfeld-com:device:ConfigDevice:1`.
  On iOS this needs Apple's multicast entitlement (see below).

### Command-line tool

```sh
swift run raumfeld --host 192.168.1.20 rooms
swift run raumfeld --host 192.168.1.20 volume Kitchen 30
swift run raumfeld --host 192.168.1.20 volume Kitchen +5
swift run raumfeld --host 192.168.1.20 toggle Kitchen
swift run raumfeld --host 192.168.1.20 now Kitchen
swift run raumfeld --host 192.168.1.20 watch
```

Run `swift run raumfeld` for all commands. `RAUMFELD_HOST=…` works instead of `--host`.
Without either, the host is discovered via SSDP.

### Tests

```sh
swift test
```

The tests use XML fixtures and a mock transport. No speakers are needed.

## iOS app: Raumfeld Remote

The project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd App
xcodegen
open RaumfeldRemote.xcodeproj
```

Set your team and bundle ID in `App/project.yml` (or in Xcode), then run it on your
iPhone. Enter the IP address of your Raumfeld host in the settings. Allow local
network access when iOS asks.

### Siri and Shortcuts

The app offers these App Intents. They show up as actions in the Shortcuts app,
and through `AppShortcutsProvider` they work in Siri without any setup:

| Intent | Example Siri phrase |
|---|---|
| Change Volume (up/down, step) | "Turn up Kitchen with Raumfeld Remote" |
| Set Volume (0–100) | "Set the volume in Kitchen with Raumfeld Remote" |
| Get Volume (returns a number) | Shortcuts only |
| Mute or Unmute | "Mute Kitchen with Raumfeld Remote" |
| Control Playback (play, pause, toggle, stop, next, previous) | "Pause Kitchen with Raumfeld Remote", "Skip Raumfeld Remote" |
| What's Playing | "What's playing in Kitchen on Raumfeld Remote" |
| Group Rooms / Ungroup Room | Shortcuts only |

Siri learns your room names from the app. They are refreshed whenever the app
sees the rooms change.

### Limitations

* **Local network only.** The Raumfeld system has no cloud API, so Siri and
  Shortcuts only work while the iPhone is on your home network.
* **Automatic discovery** needs the `com.apple.developer.networking.multicast`
  entitlement, which you [request from Apple](https://developer.apple.com/contact/request/networking-multicast).
  Until it is granted, enter the host's IP address manually. A fixed DHCP lease
  for the host in your router helps. When you have the entitlement, enable the
  commented-out `entitlements` block in `project.yml`.
* **No hardware volume buttons.** iOS only lets the volume buttons control AirPlay
  devices. Use Siri, Shortcuts, Back Tap, or the Action Button instead.

### Ideas for next steps

* A Control Center / Lock Screen volume control (iOS 18 `ControlWidget`) and
  interactive widgets. Both need an App Group so the extension can read the host
  setting (see `AppSettings`).
* A Live Activity for now playing.
* Browsing the media server (`ContentDirectory`) to start favourites or radio stations.

---

PyRaumfeld 0.5
==============

Python library for controlling the Teufel Raumfeld system

Author: Patrick Maier  
https://github.com/maierp/pyraumfeld

Based on python-raumfeld by Thomas Feldmann:  
https://github.com/tfeldmann/python-raumfeld


##The Lib provides:
* a data structure representing the Zone and room config of Raumfeld
* playback and information functionality
* functions for modifying the zone configuration
* the functionality to register a callback function which gets called as soon as the zone configuration changed
* immediate data update via long-polling of the Raumfeld WEB-API 

###Zone objects:
* Name, UDN, Location, Address (read only)
* media_info: returns hash with NrTracks, MediaDuration, CurrentURI, CurrentURIMetaData, NextURI, NextURIMetaData, PlayMedium, RecordMedium, WriteStatus (read only)
* media_info_[above names] as extra functions
* position_info: returns hash with Track, TrackDuration, TrackMetaData, TrackURI, RelTime, AbsTime, RelCount, AbsCount (read only)
* position_info[above names] as extra functions
* transport_info: returns hash with CurrentTransportState, CurrentTransportStatus, CurrentSpeed (read only)
* transport_info[above names] as extra functions
* volume, mute (read/write)
* changeVolume(amount), play(uri(optional), meta(optional)), bend(uri, meta(optional)), next(), previous(), pause(), seek(amount, unit[_ABS_TIME_|REL_TIME|TRACK_NR]), stop()
* A zone contains a list of Room objects which can be fetched with getRooms() -> returns an array
* You can search for Rooms in a Zone by calling getRoomsByName(name) -> returns array of found rooms ...
* ... or for a specific room by calling getRoomByUDN(udn) -> returns the room (None otherwise)

###Room objects:
* Name, UDN (read only)
* volume, mute (read/write)
* changeVolume(amount), play(uri(optional)), next(), previous(), pause(), seek(amount, unit[_ABS_TIME_|REL_TIME|TRACK_NR]), stop()
* A room contains a list of Renderer objects which can be fetched with getRenderers() -> returns an array
* You can search for a Renderer in a Room by calling getRenderer(name) -> returns the renderer (None otherwise)

###Renderer objects:
* Name, UDN, Location, Address (read only)
* volume, mute (read/write) 
* changeVolume(amount), play(uri(optional)), next(), previous(), pause(), seek(amount, unit[_ABS_TIME_|REL_TIME|TRACK_NR]), stop()

###MediaServer object:
* UDN, Location (read only)
* browse(object_id, browse_flag(optional), filter(optional), request_count(optional))
* browse_children(object_id, filter(optional), request_count(optional))
* search(container_id, search_criteria, filter(optional), request_count(optional))
* create_queue(desired_name, container_id)
* add_container(queue_id, container_id, source_id(optional), criteria(optional), start_index(optional), end_index(optional), position(optional))
* add_item(queue_id, object_id, position)
* move_in_queue(object_id, new_position)
* remove_from_queue(queue_id, from_position, to_position)

###Global functions are:
* setLogging(level) sets the logging level: logging.DEBUG, logging.INFO, logging.WARNING, logging.ERROR, logging.CRITICAL
* registerChangeCallback(callback) here you can register your function which should be called when something in the data structure has changed
* init(hostIP(optional)) this initializes the library and searches for the hostIP if none is provided.
* getRoomsByName(name) searches for all rooms containing the string in their name
* getRoomByUDN(udn) returns the Room object defined by the UDN
* getZones() returns the list of Zone objects
* getUnassignedRooms() returns the list of unassigned room objects
* getZonesByName(name) searches for all zones containing the string in their name
* getZoneByUDN(udn) returns the Zone object defined by the UDN
* getZoneWithRoom(room_obj) returns the Zone containing the provided room object
* getZoneWithRoomName(name) returns the Zone containing a room defined by its name
* getZoneWithRoomUDN(udn) returns the Zone containing a room defined by its UDN
* getMediaServer() returns the raumfeld media server
* getMediaServerUDN() returns the udn of the raumfeld media server

###Zone-Configuration-Functions are:
* dropRoomByUDN(udn) drops a room from its Zone
* connectRoomToZone(room_udn, [zone_udn(optional)] puts the room with the given roomUDN in the zone with the zoneUDN. If no zone_udn is provided, a new zone is created

###Global variables:
* hostBaseURL (readonly) the base URL of the host

##Sample Programs:
* PyRaumfeldSample.py: Shows the basic usage
* RaumfeldControl.py: Provides a web-based API to the Raumfeld system

###Known issues:
* Due to a bug in the Raumfeld firmware, the Zone names may be incorrect