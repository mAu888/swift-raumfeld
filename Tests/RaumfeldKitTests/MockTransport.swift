import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RaumfeldKit

/// A recorded request with its body decoded as a string.
struct RecordedRequest: Sendable {
    var url: URL
    var method: String
    /// Header names lowercased, since HTTP header names are case-insensitive
    /// (and Foundation on Linux re-capitalizes them).
    var headers: [String: String]
    var body: String

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// The SOAP action named in the `SOAPAction` header, e.g. `SetVolume`.
    var soapAction: String? {
        header("SOAPAction")?.split(separator: "#").last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
    }
}

/// An in-memory HTTP transport. Responses are produced by a handler closure.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (RecordedRequest) async throws -> (Int, [String: String], Data)

    private let lock = NSLock()
    private var _requests: [RecordedRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [RecordedRequest] {
        lock.withLock { _requests }
    }

    var soapActions: [String] {
        requests.compactMap(\.soapAction)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let recorded = RecordedRequest(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 }),
            body: request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        )
        lock.withLock { _requests.append(recorded) }
        let (status, headers, data) = try await handler(recorded)
        let response = HTTPURLResponse(url: recorded.url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }
}

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }
}

func soapResponse(_ action: String, _ values: [String: String] = [:]) -> Data {
    let body = values.map { "<\($0.key)>\($0.value.xmlEscaped)</\($0.key)>" }.joined()
    return Data("""
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
    <s:Body><u:\(action)Response xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">\(body)</u:\(action)Response></s:Body>
    </s:Envelope>
    """.utf8)
}

func soapFault(code: Int, description: String) -> Data {
    Data("""
    <?xml version="1.0"?>
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
    <s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>
    <detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode><errorDescription>\(description)</errorDescription></UPnPError></detail>
    </s:Fault></s:Body></s:Envelope>
    """.utf8)
}
