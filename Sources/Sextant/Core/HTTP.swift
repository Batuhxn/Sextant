import Foundation

/// Minimal HTTP/1.1 pieces for the in-app server that serves the web interface on 127.0.0.1.
public struct HTTPRequest: Equatable {
    public var method: String
    public var target: String          // path + query, as sent
    public var headers: [String: String]  // lower-cased names
    public var body: Data

    public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
    public var query: String? {
        let p = target.split(separator: "?", maxSplits: 1)
        return p.count > 1 ? String(p[1]) : nil
    }
    /// Path segments, percent-decoded, empty ones dropped.
    public var parts: [String] {
        path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }

    public enum ParseResult: Equatable {
        case incomplete
        case invalid
        case done(HTTPRequest, consumed: Int)
    }

    /// Parses one request from the start of `data`. Bodies are limited to `maxBody` bytes.
    public static func parse(_ data: Data, maxBody: Int = 200 * 1024 * 1024) -> ParseResult {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: sep) else { return data.count > 64 * 1024 ? .invalid : .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? -1
        guard len >= 0, len <= maxBody else { return .invalid }
        let bodyStart = end.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= len else { return .incomplete }
        let bodyEnd = data.index(bodyStart, offsetBy: len)
        let req = HTTPRequest(method: String(first[0]).uppercased(), target: String(first[1]), headers: headers,
                              body: Data(data[bodyStart..<bodyEnd]))
        return .done(req, consumed: data.distance(from: data.startIndex, to: bodyEnd))
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")], body: data)
    }

    public static func error(_ message: String, status: Int) -> HTTPResponse { json(["error": message], status: status) }

    static let reasons: [Int: String] = [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized",
                                         403: "Forbidden", 404: "Not Found", 409: "Conflict", 416: "Range Not Satisfiable",
                                         500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable"]

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var names = Set<String>()
        for (k, v) in headers { head += "\(k): \(v)\r\n"; names.insert(k.lowercased()) }
        if !names.contains("content-length") { head += "Content-Length: \(body.count)\r\n" }
        head += "Connection: close\r\n\r\n"
        var d = Data(head.utf8)
        d.append(body)
        return d
    }
}

/// `Range: bytes=a-b` for a file of `size` bytes. nil = whole file; .unsatisfiable = 416.
public enum ByteRange: Equatable {
    case whole
    case part(ClosedRange<Int>)
    case unsatisfiable

    public static func parse(_ header: String?, size: Int) -> ByteRange {
        guard let h = header?.trimmingCharacters(in: .whitespaces), h.hasPrefix("bytes=") else { return .whole }
        let spec = h.dropFirst(6)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .whole }
        let a = spec[..<dash], b = spec[spec.index(after: dash)...]
        if a.isEmpty && b.isEmpty { return .whole }
        var start: Int, end: Int
        if a.isEmpty {  // last N bytes
            guard let n = Int(b) else { return .whole }
            start = max(0, size - n); end = size - 1
        } else {
            guard let s = Int(a) else { return .whole }
            start = s
            end = b.isEmpty ? size - 1 : min(Int(b) ?? (size - 1), size - 1)
        }
        if size == 0 || start > end || start >= size { return .unsatisfiable }
        return .part(start...end)
    }
}

/// `sextant://pair?u=<server url>&t=<key>`, the link inside the QR code on the computer.
public struct PairLink: Equatable {
    public var server: String
    public var token: String

    public static func parse(_ url: URL) -> PairLink? {
        guard url.scheme?.lowercased() == "sextant", url.host?.lowercased() == "pair",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let u = q["u"], let t = q["t"], !t.isEmpty, let s = normalizeServer(u) else { return nil }
        return PairLink(server: s, token: t)
    }

    /// "192.168.1.5:8765" or "http://host:8765/" -> "http://host:8765"
    public static func normalizeServer(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let host = u.host, !host.isEmpty, u.path.isEmpty || u.path == "/" else { return nil }
        if u.port == nil && u.scheme == "http" { s += ":8765" }
        return s
    }
}
