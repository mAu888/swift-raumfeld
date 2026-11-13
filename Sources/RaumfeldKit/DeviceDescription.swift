import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The services listed in a UPnP device description document.
struct DeviceDescription: Sendable, Equatable {
    /// Control URL by service type (e.g. `urn:schemas-upnp-org:service:RenderingControl:1`).
    var controlURLs: [String: URL]

    /// Parses a device description. Relative control URLs are resolved against
    /// `<URLBase>` when present, otherwise against the description's own URL.
    static func parse(_ data: Data, location: URL) throws -> DeviceDescription {
        let root = try XElement.parse(data)
        let base = root.value("URLBase").flatMap { URL(string: $0) } ?? location
        var controlURLs: [String: URL] = [:]
        // Services can be nested in embedded devices; collect them all.
        for service in root.all("service") {
            guard
                let type = service.value("serviceType"),
                let path = service.value("controlURL"),
                let url = URL(string: path, relativeTo: base)?.absoluteURL
            else { continue }
            // Keep the first occurrence (the root device's service wins).
            if controlURLs[type] == nil {
                controlURLs[type] = url
            }
        }
        return DeviceDescription(controlURLs: controlURLs)
    }
}

/// Fetches and caches device descriptions so each device is only asked once.
///
/// Concurrent lookups for the same device share one request. Failed lookups are
/// remembered for `failureTTL` seconds, so a device that does not serve its
/// description does not delay every command with another failing request.
actor ServiceResolver {
    private enum Entry {
        case loaded(DeviceDescription)
        case failed(at: Date)
        case loading(Task<DeviceDescription?, Never>)
    }

    private let transport: any HTTPTransport
    private let failureTTL: TimeInterval
    private var entries: [URL: Entry] = [:]

    init(transport: any HTTPTransport, failureTTL: TimeInterval = 60) {
        self.transport = transport
        self.failureTTL = failureTTL
    }

    /// Returns a SOAP client for `service` on the device described at `location`.
    ///
    /// If the description cannot be fetched or does not list the service, the
    /// control path the original Python library hardcoded for that kind of
    /// device is used instead.
    func service(_ service: UPnPService, at location: URL, kind: DeviceKind) async -> SOAPService {
        let description = await description(at: location)
        let controlURL = description?.controlURLs[service.rawValue]
            ?? Self.fallbackURL(for: service, kind: kind, location: location)
        return SOAPService(controlURL: controlURL, serviceType: service.rawValue, transport: transport)
    }

    func invalidate() {
        entries.removeAll()
    }

    private func description(at location: URL) async -> DeviceDescription? {
        switch entries[location] {
        case let .loaded(description):
            return description
        case let .failed(date) where Date().timeIntervalSince(date) < failureTTL:
            return nil
        case let .loading(task):
            return await task.value
        case .failed, nil:
            break
        }

        let transport = self.transport
        let task = Task<DeviceDescription?, Never> {
            var request = URLRequest(url: location)
            request.timeoutInterval = 5
            guard
                let (data, response) = try? await transport.send(request),
                (200..<300).contains(response.statusCode)
            else { return nil }
            return try? DeviceDescription.parse(data, location: location)
        }
        entries[location] = .loading(task)
        let description = await task.value
        entries[location] = description.map(Entry.loaded) ?? .failed(at: Date())
        return description
    }

    static func fallbackURL(for service: UPnPService, kind: DeviceKind, location: URL) -> URL {
        var components = URLComponents()
        components.scheme = location.scheme
        components.host = location.host
        components.port = location.port
        components.path = service.fallbackControlPath(for: kind)
        return components.url ?? location
    }
}
