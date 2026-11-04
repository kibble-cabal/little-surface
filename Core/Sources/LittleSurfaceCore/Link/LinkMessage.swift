import Foundation

/// A request from the Blender add-on. The link speaks just enough HTTP for Python's standard library.
public struct LinkRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// With lowercased names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public enum LinkRequestParser {
    public enum Result: Equatable {
        case incomplete
        case complete(LinkRequest)
        case invalid
        case tooLarge
    }

    public static let headerLimit = 16 * 1024
    /// Well past the largest sculpt the app can hold as text.
    public static let bodyLimit = 1024 * 1024 * 1024

    public static func parse(_ buffer: Data) -> Result {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > headerLimit ? .tooLarge : .incomplete
        }
        guard split.lowerBound - buffer.startIndex <= headerLimit,
              let head = String(data: buffer[buffer.startIndex..<split.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard start.count == 3, start[2].hasPrefix("HTTP/1."), !start[0].isEmpty,
              let components = URLComponents(string: String(start[1])) else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else { return .invalid }
            length = value
        }
        guard length <= bodyLimit else { return .tooLarge }
        guard buffer.endIndex - split.upperBound >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let body = Data(buffer[split.upperBound..<(split.upperBound + length)])
        return .complete(LinkRequest(method: String(start[0]), path: components.path, query: query, headers: headers, body: body))
    }
}

public struct LinkResponse: Equatable {
    public var status: Int
    public var contentType: String
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, contentType: String = "application/octet-stream", headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    /// What the add-on shows when something goes wrong, or tells the artist when it goes right.
    public static func message(_ text: String, status: Int = 200) -> LinkResponse {
        json(["message": text], status: status)
    }

    public static func json(_ value: [String: Any], status: Int = 200) -> LinkResponse {
        LinkResponse(status: status, contentType: "application/json", body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data())
    }

    public var encoded: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value.filter { !$0.isNewline })\r\n"
        }
        return Data((head + "\r\n").utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Content"
        default: return "Error"
        }
    }
}
