import Foundation

@main
struct RemoteEventTests {
    static func main() throws {
        let now = Date()
        let input: [String: Any] = ["agent": "claude", "kind": "approval", "session": "same-session",
                                   "ts": now.timeIntervalSince1970, "cwd": "/srv/project", "pid": "1",
                                   "req": "123", "tty": "ttys001", "payload": "/etc/passwd", "app": "bad"]
        func normalize(_ value: [String: Any], source: String = "linux-work") throws -> [String: Any]? {
            RemoteAgentEvent.normalize(try JSONSerialization.data(withJSONObject: value), source: source, now: now)
        }
        let event = try normalize(input)!
        precondition(event["remote"] as? String == "linux-work")
        for key in ["pid", "req", "tty", "payload", "app"] { precondition(event[key] == nil) }
        for source in ["", "../host", "host\n", "host;sh", String(repeating: "a", count: 65)] {
            precondition(try! normalize(input, source: source) == nil)
        }
        for (key, value) in [("agent", "unknown"), ("kind", "execute"), ("session", ""), ("session", "bad\n")] {
            var bad = input; bad[key] = value
            precondition(try! normalize(bad) == nil)
        }
        var old = input; old["ts"] = now.timeIntervalSince1970 - 61
        precondition(try! normalize(old) == nil)
        old["ts"] = now.timeIntervalSince1970 + 61
        precondition(try! normalize(old) == nil)
        precondition(RemoteAgentEvent.normalize(Data(repeating: 32, count: 8193), source: "host") == nil)
        precondition(RemoteAgentEvent.normalize(Data("[]".utf8), source: "host") == nil)
        print("Remote event validation checks passed")
    }
}
