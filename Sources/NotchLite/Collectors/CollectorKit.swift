// Shared plumbing for the usage collectors. The collectors port the logic of
// Omarchy's agent usage collectors (MIT, Copyright (c) David Heinemeier
// Hansson, https://github.com/basecamp/omarchy) to Swift for macOS.

import Foundation
import SQLite3

// MARK: Model

struct UsageLimit: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let percent: Double // 0...1 used
    let resetsAt: Date?
    var window: TimeInterval? = nil // length of the window, when known

    /// When the limit runs out at the pace used so far in this window,
    /// if that happens before it resets.
    var runsOutAt: Date? {
        guard let window, let reset = resetsAt, percent > 0.05, percent < 1 else { return nil }
        let elapsed = window - reset.timeIntervalSinceNow
        guard elapsed > window * 0.1 else { return nil } // too early to tell
        let runout = Date().addingTimeInterval((1 - percent) * elapsed / percent)
        return runout < reset ? runout : nil
    }
}

struct LocalStats: Equatable {
    var tokensToday = 0
    var tokensWeek = 0
    var promptsToday = 0
    var sessionsToday = 0
    var topModel: String?
    var busiestDay: Date?

    var isEmpty: Bool { tokensWeek == 0 && promptsToday == 0 }
}

struct AgentUsage: Equatable {
    var plan: String?
    var limits: [UsageLimit] = []
    var note: String? // why the numbers are missing or not current (Italian)
    var extra: String? // secondary info line (Italian), e.g. reset credits
    var balance: String? // prepaid credit left, already formatted, e.g. "$12.40"
    var stats: LocalStats? // local usage, for collectors that read it themselves
    var fetchedAt: Date?

    /// In use: something to show in the Agents tab. Agents without limits or
    /// balance (not signed in, local stats only) only feed the hero line.
    var isActive: Bool { !limits.isEmpty || balance != nil }
}

/// One subscription / provider. `fetch` runs on a background queue, must be
/// read-only towards other apps' files, must send a credential only to its own
/// provider's HTTPS host, and returns nil when the agent is not used on this Mac.
protocol UsageCollector: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// SF Symbol used as the agent's mark.
    var symbol: String { get }
    func fetch(previous: AgentUsage?) -> AgentUsage?
}

// MARK: Helpers

enum Kit {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func env(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespaces),
              !value.isEmpty else { return nil }
        return value
    }

    /// `~/x` and `$VAR` expansion for paths found in config files.
    static func expand(_ path: String) -> URL {
        var text = path
        if text.hasPrefix("~/") { text = home.path + text.dropFirst(1) }
        for (key, value) in ProcessInfo.processInfo.environment {
            text = text.replacingOccurrences(of: "$\(key)", with: value)
        }
        return URL(fileURLWithPath: text)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func readText(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// First executable named `name` in PATH or the usual install locations.
    static func which(_ name: String) -> String? {
        var dirs = (env("PATH") ?? "").split(separator: ":").map(String.init)
        dirs += ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home.path)/.npm-global/bin",
                 "\(home.path)/.bun/bin", "\(home.path)/.cargo/bin", "/usr/bin"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Generic password from the login Keychain via /usr/bin/security.
    static func keychain(service: String, account: String? = nil) -> String? {
        var arguments = ["find-generic-password", "-s", service, "-w"]
        if let account { arguments.insert(contentsOf: ["-a", account], at: 1) }
        guard let data = run("/usr/bin/security", arguments, timeout: 5),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: HTTP

    struct Response {
        let status: Int // 0 = transport failure (no answer)
        let data: Data?
        let headers: [String: String]
        var json: Any? { data.flatMap { try? JSONSerialization.jsonObject(with: $0) } }
        var object: [String: Any]? { json as? [String: Any] }
        var ok: Bool { (200..<300).contains(status) }
    }

    /// Blocking request for the background queue. Never follows a redirect to
    /// another host, so a credential stays with the host it was meant for.
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                        json body: Any? = nil, rawBody: Data? = nil, timeout: TimeInterval = 10) -> Response {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("NotchLite/1.0", forHTTPHeaderField: "User-Agent")
        }
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if let rawBody {
            request.httpBody = rawBody
        }

        let result = Locked(Response(status: 0, data: nil, headers: [:]))
        let done = DispatchSemaphore(value: 0)
        let session = URLSession(configuration: .ephemeral, delegate: SameHostRedirects(), delegateQueue: nil)
        session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    headers[String(describing: key).lowercased()] = String(describing: value)
                }
                result.value = Response(status: http.statusCode, data: data, headers: headers)
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 2)
        session.invalidateAndCancel() // a slow-drip answer must not outlive the timeout
        return result.value
    }

    private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let original = task.originalRequest?.url
            let safe = request.url?.host == original?.host && request.url?.scheme == original?.scheme
            completionHandler(safe ? request : nil)
        }
    }

    /// Italian note for a failed request, in the shape every collector uses.
    static func failureNote(_ response: Response, provider: String, signIn: String) -> String {
        switch response.status {
        case 0: "\(provider) non raggiungibile, riprovo più tardi"
        case 401, 403: "Accesso rifiutato: \(signIn)"
        case 429: "\(provider) limita i controlli, riprovo più tardi"
        default: "Errore \(response.status) da \(provider)"
        }
    }

    // MARK: Processes

    /// Runs a tool and returns its stdout, or nil on failure / timeout.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval,
                    environment: [String: String]? = nil, currentDirectory: URL? = nil) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = Locked(Data())
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data.value = output.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data.value : nil
    }

    /// Starts a stdio JSON-RPC server, sends the lines, waits for the reply
    /// with `awaitID`, then stops the server.
    static func jsonRPC(executable: String, arguments: [String], lines: [String], awaitID: Int,
                        timeout: TimeInterval, environment: [String: String]? = nil) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let reply = Locked<[String: Any]?>(nil)
        let buffer = Locked(Data())
        let done = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil; done.signal(); return }
            buffer.mutate { data in
                data.append(chunk)
                while let newline = data.firstIndex(of: 0x0A) {
                    let line = data[data.startIndex..<newline]
                    data.removeSubrange(data.startIndex...newline)
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       (object["id"] as? NSNumber)?.intValue == awaitID {
                        reply.value = object
                        done.signal()
                    }
                }
            }
        }
        for line in lines {
            try? input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        }
        _ = done.wait(timeout: .now() + timeout)
        return reply.value
    }

    // MARK: SQLite (read-only)

    /// Rows as dictionaries; nil when the database can't be opened or queried.
    /// Opened read-only so another app's database is never written or locked.
    static func sqlite(_ url: URL, _ sql: String, _ parameters: [Any] = []) -> [[String: Any]]? {
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let int as Int: sqlite3_bind_int64(statement, position, Int64(int))
            case let double as Double: sqlite3_bind_double(statement, position, double)
            case let text as String: sqlite3_bind_text(statement, position, text, -1, transient)
            default: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [[String: Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return rows.isEmpty ? nil : rows }
            var row: [String: Any] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = sqlite3_column_double(statement, column)
                case SQLITE_TEXT: row[name] = String(cString: sqlite3_column_text(statement, column))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, column) {
                        row[name] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
                    }
                default: break
                }
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: Values

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue.isFinite ? number.doubleValue : nil
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: ""))
        default:
            return nil
        }
    }

    static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    /// ISO 8601 (with or without fractions), or epoch seconds / milliseconds.
    // ISO8601DateFormatter is thread-safe: build them once, not per row.
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let iso = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String, !text.isEmpty {
            if let date = isoFractional.date(from: text) ?? iso.date(from: text) { return date }
            if Double(text) == nil { return nil }
        }
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
    }

    static func limit(_ label: String, used percent: Double, resetsAt: Any? = nil, window: TimeInterval? = nil) -> UsageLimit {
        UsageLimit(label: label, percent: clamp(percent), resetsAt: date(resetsAt), window: window)
    }

    static func money(_ amount: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.locale = Locale(identifier: "it_IT")
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
    }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
