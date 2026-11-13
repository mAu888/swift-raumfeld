import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Well-known UPnP service types used by Raumfeld devices.
public enum UPnPService: String, Sendable, CaseIterable {
    case renderingControl = "urn:schemas-upnp-org:service:RenderingControl:1"
    case avTransport = "urn:schemas-upnp-org:service:AVTransport:1"
    case contentDirectory = "urn:schemas-upnp-org:service:ContentDirectory:1"
    case connectionManager = "urn:schemas-upnp-org:service:ConnectionManager:1"

    /// Control path used when the device description cannot be fetched.
    /// These are the paths the original Python library hardcoded.
    var fallbackControlPath: String {
        switch self {
        case .renderingControl: return "/RenderingControl/ctrl"
        case .avTransport: return "/AVTransport/ctrl"
        case .contentDirectory: return "/cd/Control"
        case .connectionManager: return "/ConnectionManager/ctrl"
        }
    }
}

/// Builds and parses UPnP SOAP messages.
enum SOAP {
    static func envelope(service: String, action: String, arguments: [(String, String)]) -> String {
        var body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
        body += "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" "
        body += "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        body += "<s:Body><u:\(action) xmlns:u=\"\(service)\">"
        for (name, value) in arguments {
            body += "<\(name)>\(value.xmlEscaped)</\(name)>"
        }
        body += "</u:\(action)></s:Body></s:Envelope>"
        return body
    }

    static func request(controlURL: URL, service: String, action: String, arguments: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(envelope(service: service, action: action, arguments: arguments).utf8)
        return request
    }

    /// Extracts the output arguments of a successful response.
    static func parseResponse(_ data: Data, action: String) throws -> [String: String] {
        let root = try XElement.parse(data)
        guard let response = root.first("\(action)Response") else {
            if let fault = parseFault(root, action: action) { throw fault }
            throw RaumfeldError.invalidResponse("missing \(action)Response")
        }
        var values: [String: String] = [:]
        for child in response.children {
            values[child.name] = child.text
        }
        return values
    }

    static func parseFault(_ data: Data, action: String) -> RaumfeldError? {
        guard let root = try? XElement.parse(data) else { return nil }
        return parseFault(root, action: action)
    }

    static func parseFault(_ root: XElement, action: String) -> RaumfeldError? {
        guard let fault = root.first("Fault") else { return nil }
        if let upnpError = fault.first("UPnPError") {
            return .soapFault(
                action: action,
                code: upnpError.value("errorCode").flatMap(Int.init),
                description: upnpError.value("errorDescription") ?? "UPnP error"
            )
        }
        return .soapFault(
            action: action,
            code: nil,
            description: fault.value("faultstring") ?? "SOAP fault"
        )
    }
}

/// Sends SOAP actions to one UPnP service on one device.
public struct SOAPService: Sendable {
    public let controlURL: URL
    public let serviceType: String
    let transport: any HTTPTransport

    public init(controlURL: URL, serviceType: String, transport: any HTTPTransport) {
        self.controlURL = controlURL
        self.serviceType = serviceType
        self.transport = transport
    }

    /// Invokes `action` and returns its output arguments.
    @discardableResult
    public func call(_ action: String, _ arguments: [(String, String)] = []) async throws -> [String: String] {
        let request = SOAP.request(controlURL: controlURL, service: serviceType, action: action, arguments: arguments)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let fault = SOAP.parseFault(data, action: action) { throw fault }
            throw RaumfeldError.httpStatus(response.statusCode, url: controlURL)
        }
        return try SOAP.parseResponse(data, action: action)
    }
}
