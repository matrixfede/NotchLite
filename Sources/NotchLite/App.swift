import AppKit
import Combine
import ServiceManagement

@main
enum NotchLiteMain {
    @MainActor
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        #if DEBUG
        if let index = arguments.firstIndex(of: "--render-live"), index + 1 < arguments.count {
            DebugPreviews.renderLive(to: arguments[index + 1])
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--render-previews"), index + 1 < arguments.count {
            DebugPreviews.render(to: arguments[index + 1])
            exit(0)
        }
        #endif
        if arguments.contains("--install-hooks") || arguments.contains("--uninstall-hooks") {
            do {
                if arguments.contains("--install-hooks") { try AgentHooks.install() } else { try AgentHooks.uninstall() }
                for target in AgentHooks.availableTargets { print("OK \(target.agent.displayName): \(target.settingsURL.path)") }
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Errore: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        if arguments.contains("--usage-report") {
            UsageReport.run()
            exit(0)
        }
        if arguments.contains("--enable-login") || arguments.contains("--disable-login") {
            do {
                if arguments.contains("--enable-login") { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                print("OK: avvio al login \(SMAppService.mainApp.status == .enabled ? "attivo" : "disattivato")")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Errore: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private let media = MediaService()
    private let battery = BatteryService()
    private let volume = VolumeService()
    private let agents = AgentService()
    private let usage = UsageService()
    private let ambient = Ambient()
    private lazy var model = IslandModel(settings: settings, media: media, agents: agents, battery: battery,
                                         usage: usage, ambient: ambient)
    private var notch: NotchController?
    private var menu: MenuController?
    private var settingsObserver: AnyCancellable?
    private var isDuplicate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            isDuplicate = true
            NSApp.terminate(nil)
            return
        }

        battery.onEvent = { [weak self] event in
            guard let self, self.settings.battery else { return }
            switch event {
            case .plugged(let level): self.model.show(.charging(level: level, plugged: true))
            case .unplugged(let level): self.model.show(.charging(level: level, plugged: false))
            case .low(let level): self.model.show(.lowBattery(level: level), for: 4)
            }
        }
        volume.onChange = { [weak self] level, muted in
            guard let self, self.settings.volumeHUD else { return }
            self.model.show(.volume(level: level, muted: muted))
        }
        agents.onAlert = { [weak self] session in
            guard let self, self.settings.agentSounds, let sound = session.state.soundName else { return }
            NSSound(named: sound)?.play()
        }
        usage.onThreshold = { [weak self] agent, limit in
            guard let self, self.settings.agentLimits else { return }
            self.model.show(.usage(agent: agent, percent: limit.percent), for: 5)
            if self.settings.agentSounds { NSSound(named: "Sosumi")?.play() }
        }

        ambient.timer.onFinish = { [weak self] label in
            self?.model.show(.timer(label: label), for: 8)
            NSSound(named: "Glass")?.play()
        }

        battery.start()
        ambient.servers.start()
        AgentHooks.refreshScriptIfInstalled()
        notch = NotchController(model: model)
        notch?.start()
        SettingsActions.servers = ambient.servers
        SettingsActions.onDialog = { [weak self] open in self?.notch?.setHidden(open) }
        menu = MenuController(usage: usage)

        applySettings()
        Guide.showIfNeeded()
        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applySettings() } }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !isDuplicate else { return } // the running copy owns the shared state
        media.stop()
        agents.stop()
        volume.stop()
        usage.stop()
        AgentService.setApproveFromNotch(false) // no hook waits for a closed app
    }

    private func applySettings() {
        settings.music ? media.start() : media.stop()
        settings.volumeHUD ? volume.start() : volume.stop()
        settings.agentSessions ? agents.start() : agents.stop()
        settings.agentLimits ? usage.start() : usage.stop()
        AgentService.setApproveFromNotch(settings.agentSessions && settings.approveFromNotch)
        settings.calendar ? ambient.calendar.start() : ambient.calendar.stop()
        settings.privacyDots ? ambient.privacy.start() : ambient.privacy.stop()
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != me }
    }
}

@MainActor
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var music: Bool { didSet { defaults.set(music, forKey: "music") } }
    @Published var battery: Bool { didSet { defaults.set(battery, forKey: "battery") } }
    @Published var volumeHUD: Bool { didSet { defaults.set(volumeHUD, forKey: "volumeHUD") } }
    @Published var agentSessions: Bool { didSet { defaults.set(agentSessions, forKey: "agentSessions") } }
    @Published var agentLimits: Bool { didSet { defaults.set(agentLimits, forKey: "agentLimits") } }
    @Published var agentSounds: Bool { didSet { defaults.set(agentSounds, forKey: "agentSounds") } }
    @Published var approveFromNotch: Bool { didSet { defaults.set(approveFromNotch, forKey: "approveFromNotch") } }
    @Published var calendar: Bool { didSet { defaults.set(calendar, forKey: "calendar") } }
    @Published var privacyDots: Bool { didSet { defaults.set(privacyDots, forKey: "privacyDots") } }
    @Published var quickReplies: [String] { didSet { defaults.set(quickReplies, forKey: "quickReplies") } }

    init() {
        defaults.register(defaults: [
            "music": true, "battery": true, "volumeHUD": true,
            "agentSessions": true, "agentLimits": true, "agentSounds": true,
            "approveFromNotch": true, "calendar": true, "privacyDots": true,
            "quickReplies": ["Sì, procedi", "Continua", "Esegui i test", "/compact"],
        ])
        music = defaults.bool(forKey: "music")
        battery = defaults.bool(forKey: "battery")
        volumeHUD = defaults.bool(forKey: "volumeHUD")
        agentSessions = defaults.bool(forKey: "agentSessions")
        agentLimits = defaults.bool(forKey: "agentLimits")
        agentSounds = defaults.bool(forKey: "agentSounds")
        approveFromNotch = defaults.bool(forKey: "approveFromNotch")
        calendar = defaults.bool(forKey: "calendar")
        privacyDots = defaults.bool(forKey: "privacyDots")
        quickReplies = defaults.stringArray(forKey: "quickReplies") ?? []
    }
}

/// Menu-bar icon: only quits the app (settings live in the notch).
@MainActor
final class MenuController: NSObject {
    private let usage: UsageService
    private var urgentObserver: AnyCancellable?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    init(usage: UsageService) {
        self.usage = usage
        super.init()
        updateIcon(urgent: false)
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Esci da NotchLite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
        // Like Omarchy's bar icon: turns urgent when a limit reaches 90%.
        urgentObserver = usage.$usage.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon(urgent: self?.usage.isUrgent ?? false) } }
        }
    }

    private func updateIcon(urgent: Bool) {
        let name = urgent ? "exclamationmark.triangle.fill" : "rectangle.topthird.inset.filled"
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "NotchLite") {
            image.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = urgent ? "!" : "◗"
        }
    }
}

/// What the notch settings tab does beyond flipping a preference.
@MainActor
enum SettingsActions {
    static var servers: ServerMonitor?

    static func addServer() {
        guard let servers, let values = askText(title: "Aggiungi un server locale", info: "NotchLite controlla ogni minuto se risponde.",
                                                placeholders: ["Nome (es. Qwen)", "Indirizzo (es. http://192.168.1.10:8080)"]) else { return }
        var text = values[1]
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil, ["http", "https"].contains(url.scheme ?? "") else {
            let error = NSAlert()
            error.messageText = "Indirizzo non valido"
            error.informativeText = "Usa un indirizzo come http://192.168.1.10:8080"
            present(error)
            return
        }
        servers.add(name: values[0].isEmpty ? (url.host ?? "Server") : values[0], url: url)
    }

    static func addTimer(to timer: TimerService) {
        guard let values = askText(title: "Nuovo promemoria", info: "Il notch ti avvisa allo scadere.",
                                   placeholders: ["Minuti (es. 40)", "Testo (es. Togli la pasta)"]) else { return }
        guard let minutes = Double(values[0].replacingOccurrences(of: ",", with: ".")), minutes > 0, minutes <= 24 * 60 else { return }
        timer.start(minutes: minutes, label: values[1])
    }

    static func addReply(to settings: Settings) {
        guard let text = askText(title: "Aggiungi una risposta rapida", info: "Verrà scritta nel terminale dell'agente con Invio.",
                                 placeholders: ["Es. Fai il commit"])?.first, !text.isEmpty else { return }
        settings.quickReplies.append(text)
    }

    /// Small modal form: one text field per placeholder. Nil when cancelled.
    private static func askText(title: String, info: String, placeholders: [String]) -> [String]? {
        // Fixed frames: a stack view here collapses the fields to zero width.
        let height = CGFloat(placeholders.count) * 32 - 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: height))
        let fields = placeholders.enumerated().map { index, placeholder in
            let field = NSTextField(frame: NSRect(x: 0, y: height - 24 - CGFloat(index) * 32, width: 300, height: 24))
            field.placeholderString = placeholder
            container.addSubview(field)
            return field
        }
        zip(fields, fields.dropFirst()).forEach { $0.nextKeyView = $1 }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.accessoryView = container
        alert.addButton(withTitle: "Aggiungi")
        alert.addButton(withTitle: "Annulla")
        alert.window.initialFirstResponder = fields.first
        guard present(alert) == .alertFirstButtonReturn else { return nil }
        return fields.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    static func toggleHooks(installed: Bool) {
        let alert = NSAlert()
        do {
            if installed {
                try AgentHooks.uninstall()
                alert.messageText = "Hook rimossi"
                alert.informativeText = "NotchLite non riceverà più eventi da Claude Code e Codex."
            } else {
                try AgentHooks.install()
                alert.messageText = "Hook installati"
                alert.informativeText = "Gli eventi arriveranno dalle nuove sessioni. Codex chiederà di approvare i nuovi hook al primo avvio. Backup: settings.json.notchlite.bak / hooks.json.notchlite.bak"
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Operazione non riuscita"
            alert.informativeText = error.localizedDescription
        }
        present(alert)
    }

    /// Hides the notch while a dialog is open: its panel sits above every
    /// window and would cover the dialog and take its clicks.
    static var onDialog: ((Bool) -> Void)?

    @discardableResult
    private static func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        onDialog?(true)
        defer { onDialog?(false) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("NotchLite: launch at login failed: \(error.localizedDescription)")
        }
    }
}
