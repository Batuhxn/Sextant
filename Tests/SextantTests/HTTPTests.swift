import XCTest

final class HTTPTests: XCTestCase {
    func testParseGetWithQuery() {
        let raw = Data("GET /api/find?q=kirke%20son HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-99\r\n\r\n".utf8)
        guard case .done(let r, let used) = HTTPRequest.parse(raw) else { return XCTFail("parse") }
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/api/find")
        XCTAssertEqual(r.query, "q=kirke%20son")
        XCTAssertEqual(r.parts, ["api", "find"])
        XCTAssertEqual(r.headers["range"], "bytes=0-99")
        XCTAssertEqual(used, raw.count)
    }

    func testBodyNeedsContentLength() {
        let head = "POST /api/songs/x/edits HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        XCTAssertEqual(HTTPRequest.parse(Data((head + "12345").utf8)), .incomplete)
        guard case .done(let r, _) = HTTPRequest.parse(Data((head + "1234567890").utf8)) else { return XCTFail("parse") }
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "1234567890")
    }

    func testPercentDecodedParts() {
        guard case .done(let r, _) = HTTPRequest.parse(Data("GET /media/son-feci-kirke/full.mp3 HTTP/1.1\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(r.parts, ["media", "son-feci-kirke", "full.mp3"])
    }

    func testGarbageIsInvalid() {
        XCTAssertEqual(HTTPRequest.parse(Data("HELLO\r\n\r\n".utf8)), .invalid)
    }

    func testRanges() {
        XCTAssertEqual(ByteRange.parse(nil, size: 100), .whole)
        XCTAssertEqual(ByteRange.parse("bytes=0-9", size: 100), .part(0...9))
        XCTAssertEqual(ByteRange.parse("bytes=90-", size: 100), .part(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=-10", size: 100), .part(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=50-500", size: 100), .part(50...99))
        XCTAssertEqual(ByteRange.parse("bytes=200-300", size: 100), .unsatisfiable)
    }

    func testResponseHeaders() {
        let s = String(data: HTTPResponse.json(["ok": true]).serialized(), encoding: .utf8)!
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("Content-Length: 11\r\n"))
        XCTAssertTrue(s.hasSuffix("{\"ok\":true}"))
    }

    func testPairLink() {
        let u = URL(string: "sextant://pair?u=http%3A%2F%2F192.168.1.20%3A8765&t=abc_DEF-123")!
        XCTAssertEqual(PairLink.parse(u), PairLink(server: "http://192.168.1.20:8765", token: "abc_DEF-123"))
        XCTAssertNil(PairLink.parse(URL(string: "https://example.com/pair?u=x&t=y")!))
        XCTAssertNil(PairLink.parse(URL(string: "sextant://pair?u=http%3A%2F%2Fh")!))
        XCTAssertEqual(PairLink.normalizeServer("192.168.1.20"), "http://192.168.1.20:8765")
        XCTAssertEqual(PairLink.normalizeServer("http://10.0.0.5:9000/"), "http://10.0.0.5:9000")
        XCTAssertNil(PairLink.normalizeServer("http://10.0.0.5:9000/api"))
    }

    func testSongIndexMerge() {
        let remote: [[String: Any]] = [["id": "a", "title": "A", "status": "done"], ["id": "b", "title": "B", "status": "working"]]
        let local: [String: [String: Any]] = ["a": ["id": "a", "title": "A"], "c": ["id": "c", "title": "C", "bpm": 120, "lyr_status": "working"]]
        let m = SongIndex.merge(remote: remote, local: local)
        XCTAssertEqual(m.map { $0["id"] as? String }, ["a", "b", "c"])
        XCTAssertEqual(m[0]["offline"] as? Bool, true)
        XCTAssertEqual(m[1]["offline"] as? Bool, false)
        XCTAssertEqual(m[2]["remote"] as? Bool, false)
        XCTAssertEqual(m[2]["lyr_status"] as? String, "done")
        let off = SongIndex.merge(remote: nil, local: local)
        XCTAssertEqual(off.count, 2)
        XCTAssertTrue(off.allSatisfy { $0["remote"] as? Bool == false })
    }
}
