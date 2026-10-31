import AppKit

/// Terminal integration through AppleScript (iTerm2 when installed, Terminal
/// otherwise): open a new agent session, bring an agent's own tab forward, or
/// type a reply into it.
enum AgentLauncher {
    private static let iTerm = "com.googlecode.iterm2"
    private static let terminal = "com.apple.Terminal"

    /// Opens a new terminal window running an agent (Omarchy's ">_" button).
    static func launch(_ agent: AgentName) {
        let command = agent.rawValue
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: iTerm) != nil {
            run("""
            tell application "iTerm"
                activate
                set newWindow to (create window with default profile)
                tell current session of newWindow to write text "\(command)"
            end tell
            """)
        } else {
            run("""
            tell application "Terminal"
                activate
                do script "\(command)"
            end tell
            """)
        }
    }

    /// Selects the window/tab whose session runs on `tty` (e.g. /dev/ttys003);
    /// falls back to just activating the app.
    static func focus(tty: String?, appBundleID: String?) {
        if !inTab(tty: tty, appBundleID: appBundleID,
                  iTerm: "select aWindow\nselect aTab\nselect aSession\nactivate",
                  terminal: "set selected of aTab to true\nset index of aWindow to 1\nactivate") {
            activate(appBundleID)
        }
    }

    /// Types `text` + Return into the agent's own tab, without stealing focus.
    static func send(_ text: String, tty: String?, appBundleID: String?) {
        let quoted = "\"" + text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        _ = inTab(tty: tty, appBundleID: appBundleID,
                  iTerm: "tell aSession to write text \(quoted)",
                  terminal: "do script \(quoted) in aTab")
    }

    static func canSendKeys(to appBundleID: String?) -> Bool { appBundleID == iTerm }

    /// Presses Esc in the agent's iTerm session.
    static func sendEscape(tty: String?, appBundleID: String?) {
        _ = inTab(tty: tty, appBundleID: appBundleID,
                  iTerm: "tell aSession to write text (character id 27) newline no", terminal: "")
    }

    /// Runs `iTerm` / `terminal` AppleScript on the tab whose tty matches.
    /// Returns false when the terminal app or tty isn't one we can address.
    private static func inTab(tty: String?, appBundleID: String?, iTerm iTermAction: String, terminal terminalAction: String) -> Bool {
        guard let tty, tty.range(of: #"^/dev/ttys?[0-9]+$"#, options: .regularExpression) != nil else { return false }
        switch appBundleID {
        case iTerm:
            run("""
            tell application "iTerm"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        repeat with aSession in sessions of aTab
                            if tty of aSession is "\(tty)" then
                                \(iTermAction)
                                return
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case terminal:
            run("""
            tell application "Terminal"
                repeat with aWindow in windows
                    repeat with aTab in tabs of aWindow
                        if tty of aTab is "\(tty)" then
                            \(terminalAction)
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
        default:
            return false
        }
        return true
    }

    private static func activate(_ bundleID: String?) {
        guard let bundleID else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }

    /// One script at a time: rapid clicks don't race each other.
    private static let queue = DispatchQueue(label: "NotchLite.AppleScript", qos: .userInitiated)

    private static func run(_ source: String) {
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error { NSLog("NotchLite: AppleScript failed: \(error)") }
        }
    }
}
