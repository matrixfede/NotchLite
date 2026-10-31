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

        battery.start()
        ambient.servers.start()
        AgentHooks.refreshScriptIfInstalled()
        notch = NotchController(model: model)
        notch?.start()
        menu = MenuController(settings: settings, usage: usage, servers: ambient.servers)

        applySettings()
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

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let settings: Settings
    private let usage: UsageService
    private let servers: ServerMonitor
    private var urgentObserver: AnyCancellable?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    init(settings: Settings, usage: UsageService, servers: ServerMonitor) {
        self.settings = settings
        self.usage = usage
        self.servers = servers
        super.init()
        updateIcon(urgent: false)
        menu.delegate = self
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addToggle("Musica", settings.music) { $0.music.toggle() }
        addToggle("Batteria e ricarica", settings.battery) { $0.battery.toggle() }
        addToggle("HUD volume", settings.volumeHUD) { $0.volumeHUD.toggle() }
        addToggle("Sessioni agenti live", settings.agentSessions) { $0.agentSessions.toggle() }
        addToggle("Limiti e statistiche agenti", settings.agentLimits) { $0.agentLimits.toggle() }
        addToggle("Approva i permessi dal notch", settings.approveFromNotch) { $0.approveFromNotch.toggle() }
        addToggle("Suoni avvisi", settings.agentSounds) { $0.agentSounds.toggle() }
        addToggle("Prossimo evento del calendario", settings.calendar) { $0.calendar.toggle() }
        addToggle("Indicatore microfono e fotocamera", settings.privacyDots) { $0.privacyDots.toggle() }
        menu.addItem(serversItem())
        menu.addItem(repliesItem())
        menu.addItem(.separator())

        for agent in AgentName.allCases {
            menu.addItem(item("Nuova sessione \(agent.displayName)") { AgentLauncher.launch(agent) })
        }
        let hooksInstalled = AgentHooks.isInstalled()
        menu.addItem(item(hooksInstalled ? "Rimuovi hook Claude Code / Codex" : "Installa hook Claude Code / Codex…") { [weak self] in
            self?.toggleHooks(installed: hooksInstalled)
        })
        let loginItem = item("Avvia al login") { Self.toggleLaunchAtLogin() }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(item("Esci da NotchLite") { NSApp.terminate(nil) })
    }

    private func addToggle(_ title: String, _ isOn: Bool, _ change: @escaping (Settings) -> Void) {
        let menuItem = item(title) { [weak self] in
            guard let self else { return }
            change(self.settings)
        }
        menuItem.state = isOn ? .on : .off
        menu.addItem(menuItem)
    }

    private func item(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: #selector(ClosureTarget.invoke), keyEquivalent: "")
        let target = ClosureTarget(action)
        menuItem.target = target
        menuItem.representedObject = target // keeps the target alive with the item
        return menuItem
    }

    /// "Server locali" submenu: one entry per server (with its state) to remove
    /// it, plus "Aggiungi server…".
    private func serversItem() -> NSMenuItem {
        let submenu = NSMenu()
        for server in servers.servers {
            let state = server.isUp == nil ? "…" : server.isUp! ? "attivo" : "non raggiungibile"
            let entry = NSMenuItem(title: "\(server.name) — \(state)", action: nil, keyEquivalent: "")
            entry.submenu = NSMenu()
            entry.submenu?.addItem(item(server.url.absoluteString) {})
            entry.submenu?.addItem(item("Rimuovi") { [weak self] in self?.servers.remove(server.name) })
            submenu.addItem(entry)
        }
        if !servers.servers.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(item("Aggiungi server…") { [weak self] in self?.addServer() })
        let parent = NSMenuItem(title: "Server locali", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    private func addServer() {
        guard let values = askText(title: "Aggiungi un server locale", info: "NotchLite controlla ogni minuto se risponde.",
                                   placeholders: ["Nome (es. Qwen)", "Indirizzo (es. http://192.168.1.10:8080)"]) else { return }
        var text = values[1]
        if !text.contains("://") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil, ["http", "https"].contains(url.scheme ?? "") else {
            let error = NSAlert()
            error.messageText = "Indirizzo non valido"
            error.informativeText = "Usa un indirizzo come http://192.168.1.10:8080"
            error.runModal()
            return
        }
        servers.add(name: values[0].isEmpty ? (url.host ?? "Server") : values[0], url: url)
    }

    /// "Risposte rapide" submenu: each reply (click to remove) plus "Aggiungi risposta…".
    private func repliesItem() -> NSMenuItem {
        let submenu = NSMenu()
        for reply in settings.quickReplies {
            let entry = NSMenuItem(title: reply, action: nil, keyEquivalent: "")
            entry.submenu = NSMenu()
            entry.submenu?.addItem(item("Rimuovi") { [weak self] in self?.settings.quickReplies.removeAll { $0 == reply } })
            submenu.addItem(entry)
        }
        if !settings.quickReplies.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(item("Aggiungi risposta…") { [weak self] in
            guard let self, let text = self.askText(title: "Aggiungi una risposta rapida",
                                                    info: "Verrà scritta nel terminale dell'agente con Invio.",
                                                    placeholders: ["Es. Fai il commit"])?.first, !text.isEmpty else { return }
            self.settings.quickReplies.append(text)
        })
        let parent = NSMenuItem(title: "Risposte rapide", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// Small modal form: one text field per placeholder. Nil when cancelled.
    private func askText(title: String, info: String, placeholders: [String]) -> [String]? {
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
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return fields.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    private func toggleHooks(installed: Bool) {
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
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func toggleLaunchAtLogin() {
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

private final class ClosureTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke() { action() }
}
