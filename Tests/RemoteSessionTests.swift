import Foundation

@main
struct RemoteSessionTests {
    @MainActor static func main() {
        let service = AgentService()
        let now = Date().timeIntervalSince1970
        let local: [String: Any] = ["agent": "claude", "kind": "working", "session": "shared", "ts": now]
        service.debugInject(local)
        var remote = local
        remote["remote"] = "linux-work"
        remote["kind"] = "approval"
        remote["cwd"] = "/srv/project"
        remote["pid"] = "999999"
        remote["req"] = "999999-1"
        remote["tty"] = "ttys001"
        remote["payload"] = "/etc/passwd"
        service.debugInject(remote)
        precondition(service.sessions.count == 2)
        let row = service.sessions.first { $0.remoteHost != nil }!
        precondition(row.project == "project · linux-work")
        precondition(row.pid == nil && row.requestID == nil && row.tty == nil && row.summary == nil)
        precondition(!service.canReply(to: row) && !service.canInterrupt(row))
        remote["remote"] = "second-host"
        service.debugInject(remote)
        precondition(service.sessions.count == 3)
        remote["kind"] = "end"
        service.debugInject(remote)
        precondition(service.sessions.count == 2)
        service.stop()
        print("Remote/local session isolation checks passed")
    }
}
