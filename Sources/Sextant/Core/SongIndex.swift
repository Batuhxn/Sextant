import Foundation

/// Builds the song list the web interface shows, from the computer's list (if reachable) and the
/// songs downloaded to the phone. Pure logic so it can be unit tested.
public enum SongIndex {
    /// - remote: `/api/songs` from the computer, or nil when it can't be reached.
    /// - local: payloads of downloaded songs (`/api/songs/<id>` as saved at download time), by id.
    public static func merge(remote: [[String: Any]]?, local: [String: [String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var seen = Set<String>()
        if let remote {
            for var s in remote {
                guard let id = s["id"] as? String else { continue }
                s["offline"] = local[id] != nil
                s["remote"] = true
                out.append(s)
                seen.insert(id)
            }
        }
        // Downloaded songs the computer doesn't list (it is off, or the song was deleted there).
        let rest = local.filter { !seen.contains($0.key) }
            .sorted { ($0.value["title"] as? String ?? "") < ($1.value["title"] as? String ?? "") }
        for (id, p) in rest {
            var s: [String: Any] = ["id": id, "status": "done", "offline": true, "remote": false]
            for k in ["title", "bpm", "duration", "art", "lyr_status", "artist", "track"] { if let v = p[k] { s[k] = v } }
            if s["title"] == nil { s["title"] = id }
            if s["lyr_status"] as? String == "queued" || s["lyr_status"] as? String == "working" { s["lyr_status"] = "done" }
            out.append(s)
        }
        return out
    }
}
