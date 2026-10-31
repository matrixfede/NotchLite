import AppKit
import Combine

enum HUD: Equatable {
    case volume(level: Float, muted: Bool)
    case charging(level: Int, plugged: Bool)
    case lowBattery(level: Int)
    case usage(agent: String, percent: Double)
}

enum IslandTab: String {
    case now, agents, settings
}

/// One side of the closed island, next to the physical notch.
enum WingContent: Equatable {
    case none
    case artwork
    case equalizer
    case agentGlyph(AgentName)
    case working(count: Int)
}

/// What the closed island shows.
enum CompactActivity: Equatable {
    case none
    case alert(AgentSession) // both wings: icon + label
    case hud(HUD) // both wings
    case wings(leading: WingContent, trailing: WingContent)
}

@MainActor
final class IslandModel: ObservableObject {
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published private(set) var isExpanded = false
    @Published private(set) var hud: HUD?
    @Published var tab: IslandTab = .now
    /// Height of the expanded content, measured by the view itself.
    @Published var contentHeight: CGFloat = 120
    /// Tallest the island may get (set from the overlay window size).
    var maxHeight: CGFloat = 520

    let settings: Settings
    let media: MediaService
    let agents: AgentService
    let battery: BatteryService
    let usage: UsageService
    let ambient: Ambient

    static let expandedWidth: CGFloat = 480
    static let maxSessionRows = 3

    private var hudWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var isHovering = false
    private var forwarders: [AnyCancellable] = []

    init(settings: Settings, media: MediaService, agents: AgentService, battery: BatteryService,
         usage: UsageService, ambient: Ambient) {
        self.settings = settings
        self.media = media
        self.agents = agents
        self.battery = battery
        self.usage = usage
        self.ambient = ambient
        // The island geometry depends on these, so re-render when they change.
        let publishers = [media.objectWillChange, agents.objectWillChange, settings.objectWillChange, usage.objectWillChange,
                          ambient.servers.objectWillChange, ambient.privacy.objectWillChange, ambient.calendar.objectWillChange,
                          ambient.shelf.objectWillChange]
        for publisher in publishers {
            forwarders.append(publisher.sink { [weak self] _ in self?.objectWillChange.send() })
        }
    }

    // MARK: State

    var showsMusic: Bool { settings.music && media.track != nil }
    var isMusicPlaying: Bool { showsMusic && media.track?.isPlaying == true }
    var liveSessions: [AgentSession] { settings.agentSessions ? agents.sessions : [] }
    var workingCount: Int { settings.agentSessions ? agents.workingCount : 0 }

    var compact: CompactActivity {
        if settings.agentSessions, let alert = agents.compactAlert { return .alert(alert) }
        if let hud { return .hud(hud) }

        let working = workingCount
        switch (isMusicPlaying, working > 0) {
        case (true, true): return .wings(leading: .artwork, trailing: .working(count: working))
        case (true, false): return .wings(leading: .artwork, trailing: .equalizer)
        case (false, true): return .wings(leading: .agentGlyph(agents.workingAgent ?? .claude), trailing: .working(count: working))
        case (false, false): return .none
        }
    }

    var wingWidth: CGFloat {
        switch compact {
        case .none: 0
        case .alert: 76
        case .hud(.charging), .hud(.lowBattery), .hud(.usage): 50
        case .hud, .wings: notchSize.height + 8
        }
    }

    var visibleSessions: [AgentSession] { Array(liveSessions.prefix(Self.maxSessionRows)) }

    /// Only agents in use: those with limits or a balance to show.
    var agentsShown: [String] { settings.agentLimits ? usage.activeAgents : [] }

    /// Size of the island body (without the flared top ears).
    var size: CGSize {
        guard isExpanded else {
            return CGSize(width: notchSize.width + wingWidth * 2, height: notchSize.height)
        }
        return CGSize(
            width: max(Self.expandedWidth, notchSize.width + 160),
            height: min(notchSize.height + contentHeight, maxHeight)
        )
    }

    var earRadius: CGFloat { isExpanded ? 12 : 7 }
    var cornerRadius: CGFloat { isExpanded ? 24 : 10 }

    // MARK: Inputs

    #if DEBUG
    func debugSetExpanded(_ expanded: Bool) { isExpanded = expanded }
    #endif

    func show(_ hud: HUD, for seconds: TimeInterval = 1.6) {
        hudWork?.cancel()
        self.hud = hud
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hud = nil }
        }
        hudWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func select(_ tab: IslandTab) {
        self.tab = tab
        if tab == .agents { usage.refresh(force: false, maxLimitsAge: 120) }
    }

    func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        hoverWork?.cancel()
        // Small delays avoid accidental opens and flicker at the edges.
        let delay: TimeInterval = hovering ? 0.12 : 0.35
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHovering == hovering, self.isExpanded != hovering else { return }
                self.isExpanded = hovering
                if hovering, self.tab == .agents { self.usage.refresh(force: false, maxLimitsAge: 120) }
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
