import Foundation

/// Songs downloaded to the phone: Application Support/Songs/<id>/{payload.json, full.mp3, backing.mp3, guitar.mp3}.
final class SongStore {
    static let shared = SongStore()
    static let media = ["full.mp3", "backing.mp3", "guitar.mp3"]
    let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Songs", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var r = root
        var v = URLResourceValues(); v.isExcludedFromBackup = true  // re-downloadable from the computer
        try? r.setResourceValues(v)
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 120 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } && !id.contains("..")
    }

    func dir(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    func payloadURL(_ id: String) -> URL { dir(id).appendingPathComponent("payload.json") }
    func mediaURL(_ id: String, _ name: String) -> URL? {
        guard Self.media.contains(name) else { return nil }
        let u = dir(id).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func isDownloaded(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: payloadURL(id).path) && mediaURL(id, "full.mp3") != nil
    }

    func payload(_ id: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: payloadURL(id)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func savePayload(_ id: String, _ data: Data) throws {
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try data.write(to: payloadURL(id), options: .atomic)
    }

    func all() -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for id in ids where Self.validID(id) && isDownloaded(id) { if let p = payload(id) { out[id] = p } }
        return out
    }

    func remove(_ id: String) { try? FileManager.default.removeItem(at: dir(id)) }

    /// Downloads the song's data and audio from the computer.
    func download(_ id: String, remote: Remote) async throws {
        let (data, code) = try await remote.get("/api/songs/\(id)")
        guard code == 200, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], obj["analysis"] != nil else {
            throw RemoteError.message("Şarkı bilgisi alınamadı (\(code)).")
        }
        let tmp = root.appendingPathComponent(".\(id).part", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        for name in Self.media {
            let file = try await remote.download("/media/\(id)/\(name)")
            try FileManager.default.moveItem(at: file, to: tmp.appendingPathComponent(name))
        }
        try data.write(to: tmp.appendingPathComponent("payload.json"), options: .atomic)
        try? FileManager.default.removeItem(at: dir(id))
        try FileManager.default.moveItem(at: tmp, to: dir(id))
    }
}

enum RemoteError: LocalizedError {
    case notPaired
    case message(String)
    var errorDescription: String? {
        switch self {
        case .notPaired: return "Bilgisayar bağlı değil."
        case .message(let m): return m
        }
    }
}

/// HTTP client for Kılavuz on the computer; every request carries the pairing key.
struct Remote {
    let server: String
    let token: String

    static var current: Remote? {
        let c = ServerConfig.shared
        guard let s = c.server, let t = c.token else { return nil }
        return Remote(server: s, token: t)
    }

    func request(_ target: String, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], timeout: TimeInterval = 30) -> URLRequest? {
        guard let url = URL(string: server + target) else { return nil }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = method
        r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return r
    }

    func get(_ target: String, timeout: TimeInterval = 30) async throws -> (Data, Int) {
        guard let r = request(target, timeout: timeout) else { throw RemoteError.message("Geçersiz adres.") }
        let (d, resp) = try await URLSession.shared.data(for: r)
        return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func download(_ target: String) async throws -> URL {
        guard let r = request(target, timeout: 120) else { throw RemoteError.message("Geçersiz adres.") }
        let (file, resp) = try await URLSession.shared.download(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw RemoteError.message("Ses dosyası indirilemedi (\(code)).") }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: file, to: keep)
        return keep
    }

    /// Is Kılavuz reachable and does it accept the key?
    func ping(timeout: TimeInterval = 2.5) async -> Bool {
        guard let res = try? await get("/api/ping", timeout: timeout), res.1 == 200,
              let o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any] else { return false }
        return o["ok"] as? Bool == true
    }
}
