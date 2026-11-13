import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A minimal, immutable XML element tree.
///
/// Raumfeld responses are small, so parsing them into a tiny DOM keeps the
/// rest of the code simple. Namespace prefixes are stripped from element
/// and attribute names (`u:SetVolumeResponse` becomes `SetVolumeResponse`).
struct XElement: Sendable, Equatable {
    var name: String
    var attributes: [String: String]
    var children: [XElement]
    /// Concatenated character data directly inside this element.
    var text: String

    init(name: String, attributes: [String: String] = [:], children: [XElement] = [], text: String = "") {
        self.name = name
        self.attributes = attributes
        self.children = children
        self.text = text
    }

    /// Parses `data` and returns the document's root element.
    static func parse(_ data: Data) throws -> XElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError.map { String(describing: $0) } ?? "no root element"
            throw RaumfeldError.invalidXML(reason)
        }
        return root
    }

    static func parse(_ string: String) throws -> XElement {
        try parse(Data(string.utf8))
    }

    /// First direct child with the given local name.
    func child(_ name: String) -> XElement? {
        children.first { $0.name == name }
    }

    /// All direct children with the given local name.
    func children(_ name: String) -> [XElement] {
        children.filter { $0.name == name }
    }

    /// Depth-first search for the first descendant (including self) with the given name.
    func first(_ name: String) -> XElement? {
        if self.name == name { return self }
        for child in children {
            if let match = child.first(name) { return match }
        }
        return nil
    }

    /// All descendants (including self) with the given local name, in document order.
    func all(_ name: String) -> [XElement] {
        var result: [XElement] = []
        collect(name, into: &result)
        return result
    }

    private func collect(_ name: String, into result: inout [XElement]) {
        if self.name == name { result.append(self) }
        for child in children { child.collect(name, into: &result) }
    }

    /// Trimmed text of the first direct child with the given name.
    func value(_ childName: String) -> String? {
        child(childName)?.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    subscript(attribute: String) -> String? {
        attributes[attribute]
    }
}

private func localName(_ qualified: String) -> String {
    if let colon = qualified.lastIndex(of: ":") {
        return String(qualified[qualified.index(after: colon)...])
    }
    return qualified
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XElement] = []
    var root: XElement?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        var attributes: [String: String] = [:]
        for (key, value) in attributeDict where !key.hasPrefix("xmlns") {
            attributes[localName(key)] = value
        }
        stack.append(XElement(name: localName(elementName), attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        if stack.isEmpty {
            root = finished
        } else {
            stack[stack.count - 1].children.append(finished)
        }
    }
}

extension String {
    /// Escapes the five XML special characters.
    var xmlEscaped: String {
        var result = ""
        result.reserveCapacity(count)
        for character in self {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
