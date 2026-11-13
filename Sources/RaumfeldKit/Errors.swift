import Foundation

public enum RaumfeldError: Error, Sendable, Equatable {
    /// The host could not be found via SSDP discovery.
    case hostNotFound
    /// An HTTP request returned an unexpected status code.
    case httpStatus(Int, url: URL?)
    /// A response was not valid XML or did not have the expected structure.
    case invalidXML(String)
    case invalidResponse(String)
    /// A UPnP SOAP action failed on the device.
    case soapFault(action: String, code: Int?, description: String)
    /// The device does not offer the requested UPnP service.
    case serviceNotFound(String)
    /// No room, zone or renderer matches the given name or UDN.
    case notFound(String)
}

extension RaumfeldError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .hostNotFound:
            return "No Raumfeld host was found on the local network."
        case let .httpStatus(code, url):
            return "HTTP \(code) from \(url?.absoluteString ?? "Raumfeld host")."
        case let .invalidXML(reason):
            return "Invalid XML from Raumfeld: \(reason)"
        case let .invalidResponse(reason):
            return "Unexpected response from Raumfeld: \(reason)"
        case let .soapFault(action, code, description):
            let codeText = code.map { " (\($0))" } ?? ""
            return "\(action) failed\(codeText): \(description)"
        case let .serviceNotFound(service):
            return "The device does not offer \(service)."
        case let .notFound(what):
            return "\(what) was not found."
        }
    }
}
