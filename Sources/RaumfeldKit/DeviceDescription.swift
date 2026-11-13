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
actor ServiceResolver {
    private let transport: any HTTPTransport
    private var cache: [URL: DeviceDescription] = [:]

    init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// Returns a SOAP client for `service` on the device described at `location`.
    ///
    /// If the description cannot be fetched or does not list the service, the
    /// conventional Raumfeld control path is used instead, matching the
    /// behaviour of the original Python library.
    func service(_ service: UPnPService, at location: URL) async -> SOAPService {
        let description = await description(at: location)
        let controlURL = description?.controlURLs[service.rawValue]
            ?? Self.fallbackURL(for: service, location: location)
        return SOAPService(controlURL: controlURL, serviceType: service.rawValue, transport: transport)
    }

    func invalidate() {
        cache.removeAll()
    }

    private func description(at location: URL) async -> DeviceDescription? {
        if let cached = cache[location] { return cached }
        var request = URLRequest(url: location)
        request.timeoutInterval = 5
        guard
            let (data, response) = try? await transport.send(request),
            (200..<300).contains(response.statusCode),
            let description = try? DeviceDescription.parse(data, location: location)
        else { return nil }
        cache[location] = description
        return description
    }

    static func fallbackURL(for service: UPnPService, location: URL) -> URL {
        var components = URLComponents()
        components.scheme = location.scheme
        components.host = location.host
        components.port = location.port
        components.path = service.fallbackControlPath
        return components.url ?? location
    }
}
