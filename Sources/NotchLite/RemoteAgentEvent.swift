import Foundation
import Darwin

/// Small allowlisted wire format. SSH authenticates the sender; the forced
/// receiver command supplies its machine name, never the untrusted payload.
enum RemoteAgentEvent {
    static func normalize(_ data: Data, source: String, now: Date = Date()) -> [String: Any]? {
        guard data.count <= 8192,
              source.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#, options: .regularExpression) != nil,
              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agent = input["agent"] as? String, ["claude", "codex"].contains(agent),
              let kind = input["kind"] as? String,
              ["working", "approval", "waiting", "completed", "failed", "end"].contains(kind),
              let session = input["session"] as? String, !session.isEmpty, session.utf8.count <= 200,
              let timestamp = input["ts"] as? Double, timestamp.isFinite,
              abs(now.timeIntervalSince1970 - timestamp) <= 60 else { return nil }
        func clean(_ text: String, limit: Int) -> String {
            String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(limit))
        }
        guard clean(session, limit: 200) == session else { return nil }
        return ["agent": agent, "kind": kind, "session": session, "remote": source,
                "cwd": clean(input["cwd"] as? String ?? "", limit: 512),
                "tool": clean(input["tool"] as? String ?? "", limit: 80), "ts": timestamp]
    }

    static func receive(source: String) -> Bool {
        // Bound both input size and waiting time for a stalled SSH client.
        alarm(5)
        defer { alarm(0) }
        var data = Data()
        while data.count <= 8192 {
            guard let chunk = try? FileHandle.standardInput.read(upToCount: 8193 - data.count) else { return false }
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard let event = normalize(data, source: source),
              var line = try? JSONSerialization.data(withJSONObject: event) else { return false }
        line.append(0x0A)
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchLite")
        // Require a pre-existing app directory; this command never launches UI.
        let path = directory.appendingPathComponent("events.jsonl").path
        let fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) == $0.count }
    }
}
