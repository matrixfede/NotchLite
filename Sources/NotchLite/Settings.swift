import Foundation
import Combine

@MainActor
final class Settings: ObservableObject {
    private let defaults: UserDefaults

    @Published var hiddenAgents: Set<String> {
        didSet { defaults.set(hiddenAgents.sorted(), forKey: "hiddenAgents") }
    }

    func showsAgent(_ id: String) -> Bool { !hiddenAgents.contains(id) }

    func setAgent(_ id: String, visible: Bool) {
        if visible { hiddenAgents.remove(id) } else { hiddenAgents.insert(id) }
    }

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hiddenAgents = Set(defaults.stringArray(forKey: "hiddenAgents") ?? [])
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

