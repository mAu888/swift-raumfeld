import Foundation

/// The interesting fields of a DIDL-Lite `<item>` or `<container>`.
public struct TrackMetadata: Sendable, Hashable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtURL: URL?
    /// UPnP class, e.g. `object.item.audioItem.musicTrack` or `object.item.audioItem.audioBroadcast`.
    public var upnpClass: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtURL: URL? = nil, upnpClass: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtURL = albumArtURL
        self.upnpClass = upnpClass
    }

    /// Parses the first item or container of a DIDL-Lite document.
    /// Returns `nil` for empty strings, `NOT_IMPLEMENTED` and unparsable input.
    public init?(didl: String) {
        let trimmed = didl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "NOT_IMPLEMENTED", let root = try? XElement.parse(trimmed) else {
            return nil
        }
        guard let entry = root.first("item") ?? root.first("container") else { return nil }

        func text(_ name: String) -> String? {
            guard let value = entry.value(name), !value.isEmpty else { return nil }
            return value
        }

        title = text("title")
        artist = text("artist") ?? text("creator")
        album = text("album")
        albumArtURL = text("albumArtURI").flatMap { URL(string: $0) }
        upnpClass = text("class")

        if title == nil && artist == nil && album == nil && albumArtURL == nil {
            return nil
        }
    }

    /// A one-line description such as "Song — Artist".
    public var summary: String? {
        switch (title, artist) {
        case let (title?, artist?): return "\(title) — \(artist)"
        case let (title?, nil): return title
        case let (nil, artist?): return artist
        default: return album
        }
    }
}
