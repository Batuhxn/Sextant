import Foundation

/// Answers the web interface's requests. Downloaded songs are served from the phone; everything else
/// (search, adding songs, analysis, edits) goes to Kılavuz on the computer with the pairing key.
final class AppRouter {
    static let shared = AppRouter()
    private var onlineCache: (Date, Bool)?
    var onPaired: (() -> Void)?

    // MARK: connection state

    func isOnline(force: Bool = false) async -> Bool {
        if !force, let c = onlineCache, Date().timeIntervalSince(c.0) < 5 { return c.1 }
        guard let r = Remote.current else { return false }
        let v = await r.ping()
        onlineCache = (Date(), v)
        return v
    }

    /// Checks the address and key against the computer, then stores them.
    func pair(server raw: String, token: String) async -> String? {
        guard let server = PairLink.normalizeServer(raw) else { return "Adres anlaşılamadı. Örnek: http://192.168.1.20:8765" }
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Anahtarı yaz." }
        let r = Remote(server: server, token: t)
        guard let res = try? await r.get("/api/ping", timeout: 5) else {
            return "Bilgisayara ulaşılamadı. Kılavuz açık mı, telefon aynı Wi-Fi'da mı?"
        }
        let code = res.1
        if code == 401 { return "Anahtar yanlış." }
        guard code == 200 else { return "Bilgisayar beklenmedik bir yanıt verdi (\(code))." }
        ServerConfig.shared.save(server: server, token: t)
        onlineCache = (Date(), true)
        onPaired?()
        return nil
    }

    // MARK: routing

    func handle(_ req: HTTPRequest) async -> HTTPResponse {
        let p = req.parts
        if req.method == "GET" && (p.isEmpty || p == ["index.html"]) { return webPage() }
        if p.first == "api" && p.count >= 2 && p[1] == "app" { return await appAPI(req, Array(p.dropFirst(2))) }
        if req.method == "GET" && p == ["api", "songs"] { return await songList() }
        if req.method == "GET" && p.count == 3 && p[0] == "api" && p[1] == "songs" && SongStore.validID(p[2]) { return await song(p[2], req) }
        if req.method == "GET" && p.count == 3 && p[0] == "media" && SongStore.validID(p[1]) {
            if let u = SongStore.shared.mediaURL(p[1], p[2]) { return fileResponse(u, type: "audio/mpeg", range: req.headers["range"]) }
        }
        return await proxy(req)
    }

    private func webPage() -> HTTPResponse {
        guard let u = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web"),
              let d = try? Data(contentsOf: u) else { return .error("Arayüz dosyası bulunamadı.", status: 500) }
        return HTTPResponse(status: 200, headers: [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")], body: d)
    }

    private func appAPI(_ req: HTTPRequest, _ p: [String]) async -> HTTPResponse {
        let store = SongStore.shared
        if req.method == "GET" && p == ["state"] {
            let online = await isOnline()
            return .json(["paired": ServerConfig.shared.isPaired, "online": online, "server": ServerConfig.shared.server ?? "",
                          "downloaded": Array(store.all().keys)])
        }
        if req.method == "POST" && p == ["pair"] {
            let o = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] ?? [:]
            if let err = await pair(server: o["url"] as? String ?? "", token: o["token"] as? String ?? "") { return .error(err, status: 400) }
            return .json(["ok": true])
        }
        if p.count == 2 && p[0] == "download" && SongStore.validID(p[1]) {
            if req.method == "DELETE" { store.remove(p[1]); return .json(["ok": true]) }
            if req.method == "POST" {
                guard let r = Remote.current else { return .error(RemoteError.notPaired.localizedDescription, status: 503) }
                do { try await store.download(p[1], remote: r); return .json(["ok": true]) }
                catch { return .error(error.localizedDescription, status: 502) }
            }
        }
        return .error("bulunamadı", status: 404)
    }

    private func songList() async -> HTTPResponse {
        let local = SongStore.shared.all()
        var remote: [[String: Any]]?
        if await isOnline(), let r = Remote.current, let res = try? await r.get("/api/songs", timeout: 5), res.1 == 200 {
            remote = (try? JSONSerialization.jsonObject(with: res.0)) as? [[String: Any]]
        }
        return .json(SongIndex.merge(remote: remote, local: local))
    }

    private func song(_ id: String, _ req: HTTPRequest) async -> HTTPResponse {
        let store = SongStore.shared
        if await isOnline(), let r = Remote.current, let res = try? await r.get("/api/songs/\(id)", timeout: 6), res.1 == 200 {
            let d = res.0
            // Keep the phone's copy in step with corrections made on either side.
            if store.isDownloaded(id), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["analysis"] != nil {
                try? store.savePayload(id, d)
            }
            return HTTPResponse(status: 200, headers: [("Content-Type", "application/json; charset=utf-8"), ("Cache-Control", "no-store")], body: d)
        }
        if let p = store.payload(id) {
            var o = p
            o["offline_copy"] = true
            return .json(o)
        }
        return .error("Bu şarkı telefonda yok ve bilgisayara ulaşılamıyor.", status: 503)
    }

    private func proxy(_ req: HTTPRequest) async -> HTTPResponse {
        guard let r = Remote.current else {
            return .error("Bilgisayar bağlı değil. Kılavuz'da \"Telefona bağla\" QR kodunu okut.", status: 503)
        }
        var headers: [String: String] = [:]
        for k in ["content-type", "range"] { if let v = req.headers[k] { headers[k] = v } }
        let slow = req.parts.first == "api" && (req.parts.count > 1 && (req.parts[1] == "find" || req.method == "POST"))
        guard let ur = r.request(req.target, method: req.method, body: req.body.isEmpty ? nil : req.body, headers: headers,
                                 timeout: slow ? 120 : 30) else { return .error("Geçersiz istek.", status: 400) }
        do {
            let (d, resp) = try await URLSession.shared.data(for: ur)
            guard let h = resp as? HTTPURLResponse else { return .error("Yanıt okunamadı.", status: 502) }
            var out: [(String, String)] = []
            for k in ["Content-Type", "Content-Range", "Accept-Ranges", "Cache-Control"] {
                if let v = h.value(forHTTPHeaderField: k) { out.append((k, v)) }
            }
            return HTTPResponse(status: h.statusCode, headers: out, body: d)
        } catch {
            onlineCache = (Date(), false)
            return .error("Bilgisayara ulaşılamadı. Kılavuz açık mı, telefon aynı Wi-Fi'da mı?", status: 503)
        }
    }

    func fileResponse(_ url: URL, type: String, range: String?) -> HTTPResponse {
        guard let h = try? FileHandle(forReadingFrom: url) else { return .error("bulunamadı", status: 404) }
        defer { try? h.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        switch ByteRange.parse(range, size: size) {
        case .unsatisfiable:
            return HTTPResponse(status: 416, headers: [("Content-Range", "bytes */\(size)")])
        case .whole:
            let d = (try? h.readToEnd()) ?? Data()
            return HTTPResponse(status: 200, headers: [("Content-Type", type), ("Accept-Ranges", "bytes")], body: d)
        case .part(let r):
            try? h.seek(toOffset: UInt64(r.lowerBound))
            let d = (try? h.read(upToCount: r.count)) ?? Data()
            return HTTPResponse(status: 206, headers: [("Content-Type", type), ("Accept-Ranges", "bytes"),
                                                       ("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(size)")], body: d)
        }
    }
}
