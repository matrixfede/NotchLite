import AppKit

enum AgentName: String, CaseIterable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// Live state of one coding-agent session (omarchy-spaces style).
enum AgentState: String {
    case working, approval, waiting, completed, failed

    var priority: Int {
        switch self {
        case .approval: 0
        case .failed: 1
        case .working: 2
        case .waiting: 3
        case .completed: 4
        }
    }

    var soundName: NSSound.Name? {
        switch self {
        case .approval: "Funk"
        case .failed: "Basso"
        case .completed: "Glass"
        case .working, .waiting: nil
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String // "<agent>:<session id>"
    var agent: AgentName
    var state: AgentState
    var project: String
    var tool: String?
    var appBundleID: String?
    var pid: Int32?
    var startedAt: Date // when the current working run began
    var updatedAt: Date
    var alertUntil: Date? // visible in the closed island until then
    var requestID: String? // pending permission the notch can answer
    var tty: String? // terminal the agent runs in, to focus its tab
    var summary: String? // last assistant message, when finished

    var isAlerting: Bool { (alertUntil ?? .distantPast) > Date() }
}

/// Reads one JSON line per hook event (Claude Code and Codex) from events.jsonl,
/// written by the notchlite-hook script, and keeps one live entry per session.
@MainActor
final class AgentService: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    /// The most recent finished session, kept after its row goes away.
    @Published private(set) var lastFinished: AgentSession?
    var onAlert: ((AgentSession) -> Void)?

    nonisolated static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("NotchLite", isDirectory: true)
    nonisolated static let eventsURL = directory.appendingPathComponent("events.jsonl")

    private var watcher: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var partial = Data()
    private var deadlineTimer: Timer?
    private var livenessTimer: Timer?
    private var byID: [String: AgentSession] = [:]

    /// Finished sessions stay listed this long; idle ones without a live process too.
    private let finishedLifetime: TimeInterval = 10 * 60
    private let silentLifetime: TimeInterval = 45 * 60

    var compactAlert: AgentSession? { sessions.first { $0.isAlerting } }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }
    var workingAgent: AgentName? { sessions.first { $0.state == .working }?.agent }

    func start() {
        guard watcher == nil else { return }
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: Self.eventsURL.path) {
                FileManager.default.createFile(atPath: Self.eventsURL.path, contents: nil)
            }
        } catch {
            NSLog("NotchLite: cannot create events file: \(error.localizedDescription)")
            return
        }
        // Drop what piled up while the app was not running.
        try? Data().write(to: Self.eventsURL)
        for folder in ["payloads", "decisions"] {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(folder))
        }
        offset = 0
        watch()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        deadlineTimer?.invalidate()
        livenessTimer?.invalidate()
        deadlineTimer = nil
        livenessTimer = nil
        byID.removeAll()
        publish()
    }

    #if DEBUG
    func debugInject(_ line: [String: Any]) { apply(line) }
    #endif

    func dismiss(_ session: AgentSession) {
        byID[session.id] = nil
        if lastFinished?.id == session.id { lastFinished = nil } // closed means seen
        publish()
    }

    func activate(_ session: AgentSession) {
        AgentLauncher.focus(tty: session.tty, appBundleID: session.appBundleID)
        if session.state == .completed || session.state == .failed { dismiss(session) }
    }

    /// Can the notch type into this session's terminal tab?
    func canReply(to session: AgentSession) -> Bool {
        // Only when the agent is really waiting on you, not after a finished turn.
        session.tty != nil && session.requestID == nil && session.state == .waiting
    }

    /// Esc stops the current turn in both Claude Code and Codex (iTerm only:
    /// Terminal can't receive a bare keystroke through AppleScript).
    func canInterrupt(_ session: AgentSession) -> Bool {
        session.state == .working && session.tty != nil && AgentLauncher.canSendKeys(to: session.appBundleID)
    }

    func interrupt(_ session: AgentSession) {
        AgentLauncher.sendEscape(tty: session.tty, appBundleID: session.appBundleID)
    }

    /// Types a reply into the agent's own terminal tab.
    func reply(_ text: String, to session: AgentSession) {
        AgentLauncher.send(text, tty: session.tty, appBundleID: session.appBundleID)
    }

    /// Answers a pending permission request: the waiting hook picks the file up.
    func decide(_ session: AgentSession, allow: Bool) {
        guard let request = session.requestID, Self.isPending(request) else { return publish() }
        let directory = Self.directory.appendingPathComponent("decisions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (allow ? "allow" : "deny").write(to: directory.appendingPathComponent(request), atomically: true, encoding: .utf8)
        var entry = session
        entry.requestID = nil
        entry.state = allow ? .working : .waiting
        entry.alertUntil = nil
        byID[session.id] = entry
        publish()
    }

    /// The flag the hook checks before waiting for an answer from the notch.
    static func setApproveFromNotch(_ enabled: Bool) {
        let flag = directory.appendingPathComponent("approve-from-notch")
        if enabled {
            FileManager.default.createFile(atPath: flag.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
    }

    // MARK: File watching

    private func watch() {
        let descriptor = open(Self.eventsURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.watcher?.cancel()
                    self.watcher = nil
                    self.offset = 0
                    self.partial.removeAll()
                    self.start() // recreate the file and watch it again
                } else {
                    self.readNewLines()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private func fileSize() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: Self.eventsURL.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func readNewLines() {
        guard let handle = try? FileHandle(forReadingFrom: Self.eventsURL) else { return }
        defer { try? handle.close() }
        let size = fileSize()
        if size < offset { offset = 0; partial.removeAll() } // truncated by someone else
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return }
        offset += UInt64(data.count)
        partial.append(data)

        while let newline = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<newline]
            partial.removeSubrange(partial.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                apply(object)
            }
        }
        compactIfIdle()
    }

    /// Keeps the file small: once everything is consumed, truncate it.
    private func compactIfIdle() {
        guard partial.isEmpty, offset > 64 * 1024,
              let handle = try? FileHandle(forWritingTo: Self.eventsURL) else { return }
        defer { try? handle.close() }
        if fileSize() == offset {
            try? handle.truncate(atOffset: 0)
            offset = 0
        }
    }

    // MARK: Events

    private func apply(_ event: [String: Any]) {
        guard let kind = event["kind"] as? String else { return }
        if let timestamp = event["ts"] as? Double, Date().timeIntervalSince1970 - timestamp > 60 { return }

        let agent = AgentName(rawValue: event["agent"] as? String ?? "") ?? .claude
        let session = nonEmpty(event["session"]) ?? "default"
        let id = "\(agent.rawValue):\(session)"
        let now = Date()

        if kind == "end" {
            if byID.removeValue(forKey: id) != nil { publish() }
            return
        }
        let state: AgentState
        switch kind {
        case "working", "clear": state = .working
        case "approval": state = .approval
        case "waiting": state = .waiting
        case "completed": state = .completed
        case "failed": state = .failed
        default: return
        }

        var entry = byID[id] ?? AgentSession(
            id: id, agent: agent, state: state, project: agent.displayName, tool: nil, appBundleID: nil,
            pid: nil, startedAt: now, updatedAt: now, alertUntil: nil, requestID: nil, tty: nil, summary: nil
        )
        // An idle notification must not hide a request the notch can still answer.
        if state == .waiting, entry.state == .approval, entry.requestID.map(Self.isPending) == true { return }
        // Claude's idle reminder after a finished turn adds nothing: keep "ha finito".
        if state == .waiting, entry.state == .completed || entry.state == .failed { return }

        let previous = byID[id]?.state
        if state == .working, ![.working, .approval].contains(entry.state) || byID[id] == nil { entry.startedAt = now }
        entry.state = state
        entry.updatedAt = now
        if let cwd = nonEmpty(event["cwd"]) { entry.project = URL(fileURLWithPath: cwd).lastPathComponent }
        entry.tool = state == .approval ? nonEmpty(event["tool"]) : nil
        entry.appBundleID = nonEmpty(event["app"]) ?? entry.appBundleID
        if let pid = Int32(nonEmpty(event["pid"]) ?? ""), pid > 1 { entry.pid = pid }
        entry.tty = nonEmpty(event["tty"]).map { "/dev/" + $0 } ?? entry.tty
        // A permission_prompt notification repeats a request we may already hold.
        entry.requestID = state == .approval ? (nonEmpty(event["req"]) ?? (previous == .approval ? entry.requestID : nil)) : nil
        entry.summary = state == .completed ? nonEmpty(event["payload"]).flatMap(Self.lastMessage) : nil

        switch state {
        case .approval: entry.alertUntil = .distantFuture
        case .waiting: entry.alertUntil = now.addingTimeInterval(6)
        case .completed: entry.alertUntil = now.addingTimeInterval(4)
        case .failed: entry.alertUntil = now.addingTimeInterval(6)
        case .working: entry.alertUntil = nil
        }

        byID[id] = entry
        if state == .completed || state == .failed { lastFinished = entry }
        publish()
        if state != .working, state != previous { onAlert?(entry) }
    }

    /// The agent's final message from the Stop payload the hook saved (then deleted).
    private static func lastMessage(fromPayload path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: url) }
        guard url.path.hasPrefix(directory.path), let payload = Kit.readJSON(url),
              let text = (payload["last_assistant_message"] ?? payload["last-assistant-message"]) as? String else { return nil }
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? nil : String(flat.prefix(240))
    }

    private func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private func publish(force: Bool = false) {
        let now = Date()
        // Answered in the terminal (or timed out): the hook waiting for the
        // notch is gone, so the buttons would do nothing.
        for (id, session) in byID where session.state == .approval {
            if let request = session.requestID, !Self.isPending(request) {
                byID[id]?.state = .waiting
                byID[id]?.requestID = nil
                byID[id]?.alertUntil = nil
            }
        }
        byID = byID.filter { _, session in
            switch session.state {
            case .completed, .failed:
                return now.timeIntervalSince(session.updatedAt) < finishedLifetime
            case .working, .approval, .waiting:
                if let pid = session.pid { return Self.isAlive(pid) }
                return now.timeIntervalSince(session.updatedAt) < silentLifetime
            }
        }
        let sorted = byID.values.sorted {
            $0.state.priority != $1.state.priority ? $0.state.priority < $1.state.priority : $0.updatedAt > $1.updatedAt
        }
        if sorted != sessions {
            sessions = sorted
        } else if force {
            objectWillChange.send() // an alert deadline passed: compact visibility changed
        }
        scheduleTimers(now: now)
    }

    /// Request ids are "<hook pid>-<time>": pending while that hook still waits.
    private nonisolated static func isPending(_ request: String) -> Bool {
        Int32(request.prefix { $0 != "-" }).map(isAlive) ?? false
    }

    private nonisolated static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// One timer for the next deadline, plus a slow process check only while
    /// sessions are live — no polling when nothing is happening.
    private func scheduleTimers(now: Date) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        let deadlines = sessions.flatMap { session -> [Date] in
            var dates = [session.updatedAt.addingTimeInterval(
                session.state == .completed || session.state == .failed ? finishedLifetime : silentLifetime
            )]
            if let alert = session.alertUntil, alert != .distantFuture { dates.append(alert) }
            return dates
        }.filter { $0 > now }
        if let next = deadlines.min() {
            deadlineTimer = makeTimer(at: next.addingTimeInterval(0.05)) { $0.publish(force: true) }
        }

        // Fast while a notch request waits (it ends when answered in the terminal).
        let interval: TimeInterval? = sessions.contains { $0.requestID != nil } ? 2
            : sessions.contains { $0.pid != nil && [.working, .approval, .waiting].contains($0.state) } ? 15 : nil
        if livenessTimer?.timeInterval != interval {
            livenessTimer?.invalidate()
            livenessTimer = nil
        }
        if let interval, livenessTimer == nil {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            }
            timer.tolerance = interval / 4
            RunLoop.main.add(timer, forMode: .common)
            livenessTimer = timer
        }
    }

    private func makeTimer(at date: Date, _ action: @escaping (AgentService) -> Void) -> Timer {
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: Hooks installer (Claude Code + Codex)

enum AgentHooks {
    private static let marker = "notchlite-hook"

    static var scriptURL: URL { AgentService.directory.appendingPathComponent(marker) }

    struct Target {
        let agent: AgentName
        let settingsURL: URL
        /// (event, optional matcher, NotchLite kind)
        let entries: [(String, String?, String)]
    }

    static var targets: [Target] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let claude = environment["NOTCHLITE_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".claude/settings.json")
        let codexHome = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        let codex = environment["NOTCHLITE_CODEX_HOOKS"].map { URL(fileURLWithPath: $0) }
            ?? codexHome.appendingPathComponent("hooks.json")
        return [
            Target(agent: .claude, settingsURL: claude, entries: [
                ("UserPromptSubmit", nil, "working"),
                ("PostToolUse", nil, "working"),
                ("PermissionRequest", nil, "approval"),
                ("Notification", "permission_prompt", "approval"),
                ("Notification", "idle_prompt", "waiting"),
                ("Stop", nil, "completed"),
                ("StopFailure", nil, "failed"),
                ("SessionEnd", nil, "end"),
            ]),
            Target(agent: .codex, settingsURL: codex, entries: [
                ("UserPromptSubmit", nil, "working"),
                ("PostToolUse", nil, "working"),
                ("PermissionRequest", nil, "approval"),
                ("Stop", nil, "completed"),
                ("SessionEnd", nil, "end"),
            ]),
        ]
    }

    /// Codex is only wired when it is installed (its home exists).
    static var availableTargets: [Target] {
        targets.filter { target in
            target.agent == .claude
                || FileManager.default.fileExists(atPath: target.settingsURL.deletingLastPathComponent().path)
        }
    }

    // Usage: notchlite-hook <agent> <kind>. Reads the hook payload on stdin,
    // finds the agent's process and terminal, appends one JSON line. For a
    // Claude permission request it then waits (up to 2 min) for an answer
    // from the notch (Claude Code and Codex share the decision schema); with
    // no answer it stays silent and the terminal decides.
    private static let script = #"""
    #!/bin/sh
    # NotchLite hook for coding agents.
    agent="$1"; kind="$2"
    dir="$HOME/Library/Application Support/NotchLite"
    [ -d "$dir" ] || exit 0
    input=$(head -c 65536); cat >/dev/null 2>&1
    head=$(printf '%s' "$input" | head -c 4096 | tr -d '\n\r')
    # Top-level keys only: a nested key inside tool_input must not spoof them.
    head=${head%%\"tool_input\"*}
    field() { printf '%s' "$head" | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" | tr -d '\\"\001-\037'; }
    pid=""; p=$PPID; i=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] && [ $i -lt 6 ]; do
      set -- $(ps -o ppid=,comm= -p "$p" 2>/dev/null)
      case "$2" in
        *claude|*codex|*codex-*) pid=$p; break ;;
      esac
      p=$1; i=$((i + 1))
    done
    tty=""; [ -n "$pid" ] && tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ?')
    payload=""; req=""
    if [ "$kind" = completed ] && pgrep -xq NotchLite; then
      mkdir -p "$dir/payloads"; payload="$dir/payloads/$$.json"; printf '%s' "$input" > "$payload"
    fi
    if [ "$kind" = approval ] && [ "$(field hook_event_name)" = PermissionRequest ] \
       && [ -f "$dir/approve-from-notch" ] && pgrep -xq NotchLite; then
      req="$$-$(date +%s)"
    fi
    printf '{"agent":"%s","kind":"%s","session":"%s","cwd":"%s","tool":"%s","app":"%s","pid":"%s","tty":"%s","req":"%s","payload":"%s","ts":%s}\n' \
      "$agent" "$kind" "$(field session_id)" "$(field cwd)" "$(field tool_name)" \
      "$(printf '%s' "${__CFBundleIdentifier:-}" | tr -d '\\"')" "$pid" "$tty" "$req" "$payload" "$(date +%s)" >> "$dir/events.jsonl"
    [ -n "$req" ] || exit 0
    answer="$dir/decisions/$req"; i=0
    while [ $i -lt 600 ]; do
      if [ -f "$answer" ]; then
        case "$(cat "$answer")" in
          allow) printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}' ;;
          deny) printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Negato dal notch (NotchLite)"}}}' ;;
        esac
        rm -f "$answer"; exit 0
      fi
      sleep 0.2; i=$((i + 1))
    done
    exit 0
    """#

    /// Keeps an installed script current after an app update (it lives in
    /// NotchLite's own folder; the agents' settings are not touched).
    static func refreshScriptIfInstalled() {
        guard FileManager.default.fileExists(atPath: scriptURL.path),
              (try? String(contentsOf: scriptURL, encoding: .utf8)) != script else { return }
        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    static func isInstalled() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else { return false }
        return availableTargets.allSatisfy { target in
            (try? String(contentsOf: target.settingsURL, encoding: .utf8))?.contains(marker) == true
        }
    }

    static func install() throws {
        try FileManager.default.createDirectory(at: AgentService.directory, withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        for target in availableTargets {
            var settings = try load(target.settingsURL)
            backupOnce(target.settingsURL)
            var hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
            for (event, matcher, kind) in target.entries {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": "\"\(scriptURL.path)\" \(target.agent.rawValue) \(kind)"]],
                ]
                if let matcher { group["matcher"] = matcher }
                hooks[event] = (hooks[event] as? [Any] ?? []) + [group]
            }
            settings["hooks"] = hooks
            try save(settings, to: target.settingsURL)
        }
    }

    static func uninstall() throws {
        for target in targets where FileManager.default.fileExists(atPath: target.settingsURL.path) {
            var settings = try load(target.settingsURL)
            let hooks = removingOurs(from: settings["hooks"] as? [String: Any] ?? [:])
            settings["hooks"] = hooks.isEmpty ? nil : hooks
            try save(settings, to: target.settingsURL)
        }
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NotchLite", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(url.path) non contiene un oggetto JSON valido.",
            ])
        }
        return object
    }

    private static func save(_ settings: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url, options: .atomic)
    }

    private static func backupOnce(_ url: URL) {
        let backup = url.appendingPathExtension("notchlite.bak")
        guard FileManager.default.fileExists(atPath: url.path),
              !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: url, to: backup)
    }

    private static func removingOurs(from hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                result[event] = value
                continue
            }
            let kept: [Any] = groups.compactMap { element in
                guard var group = element as? [String: Any],
                      let handlers = group["hooks"] as? [Any] else { return element }
                let remaining = handlers.filter { handler in
                    let command = (handler as? [String: Any])?["command"] as? String ?? ""
                    return !command.contains(marker)
                }
                if remaining.isEmpty { return nil }
                group["hooks"] = remaining
                return group
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }
}
