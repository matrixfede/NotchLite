import AppKit
import SwiftUI

private let spring = Animation.spring(response: 0.36, dampingFraction: 0.82)
private let secondaryText = Color.white.opacity(0.55)

/// Notch silhouette: flared "ears" at the top, rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(radius, h / 2, (w - ear * 2) / 2)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: ear, y: ear), control: CGPoint(x: ear, y: 0))
        path.addLine(to: CGPoint(x: ear, y: h - r))
        path.addQuadCurve(to: CGPoint(x: ear + r, y: h), control: CGPoint(x: ear, y: h))
        path.addLine(to: CGPoint(x: w - ear - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w - ear, y: h - r), control: CGPoint(x: w - ear, y: h))
        path.addLine(to: CGPoint(x: w - ear, y: ear))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - ear, y: 0))
        path.closeSubpath()
        return path
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let size = model.size
        let ear = model.earRadius
        let shape = NotchShape(ear: ear, radius: model.cornerRadius)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            Group {
                if model.isExpanded {
                    ExpandedView(model: model, media: model.media, agents: model.agents,
                                 battery: model.battery, usage: model.usage)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else {
                    CompactView(model: model, media: model.media)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, ear)
        }
        .frame(width: size.width + ear * 2, height: size.height)
        .clipShape(shape)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { model.ambient.shelf.add([url]) } }
                }
            }
            return true
        }
        .shadow(color: .black.opacity(model.isExpanded ? 0.45 : 0), radius: 12, y: 4)
        .animation(spring, value: size)
        .animation(spring, value: model.isExpanded)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Compact (closed) island

private struct CompactView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var media: MediaService

    var body: some View {
        let wing = model.wingWidth
        HStack(spacing: 0) {
            leading.frame(width: wing, alignment: .center)
            Color.clear.frame(width: model.notchSize.width)
            trailing.frame(width: wing, alignment: .center)
        }
        .frame(height: model.notchSize.height)
        .overlay(alignment: .trailing) { PrivacyDots(privacy: model.ambient.privacy).padding(.trailing, 4) }
        .animation(spring, value: model.compact)
    }

    @ViewBuilder private var leading: some View {
        switch model.compact {
        case .none:
            EmptyView()
        case .alert(let session):
            StateIcon(state: session.state, size: 13)
        case .hud(let hud):
            Image(systemName: hud.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hud.color)
        case .wings(let content, _):
            wing(content)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.compact {
        case .none:
            EmptyView()
        case .alert(let session):
            Text(session.state.shortLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(session.state.color)
                .lineLimit(1)
        case .hud(.volume(let level, let muted)):
            LevelBar(value: muted ? 0 : Double(level), color: .white)
                .frame(width: model.notchSize.height - 4, height: 5)
        case .hud(.charging(let level, _)):
            percentText(level, color: .white)
        case .hud(.lowBattery(let level)):
            percentText(level, color: .red)
        case .hud(.usage(_, let percent)):
            percentText(Int(percent * 100), color: meterColor(percent))
        case .hud(.timer(let label)):
            Text(label.isEmpty ? "Finito" : label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .padding(.horizontal, 4)
        case .wings(_, let content):
            wing(content)
        }
    }

    private func percentText(_ value: Int, color: Color) -> some View {
        Text("\(value)%")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
    }

    @ViewBuilder private func wing(_ content: WingContent) -> some View {
        switch content {
        case .none:
            EmptyView()
        case .artwork:
            Artwork(image: media.artwork, size: model.notchSize.height - 12, corner: 5)
        case .equalizer:
            Equalizer(color: Color(nsColor: media.tint))
        case .agentGlyph(let agent):
            AgentMark(agent: agent, size: 16)
        case .working(let count):
            HStack(spacing: 4) {
                Spinner()
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        case .timer:
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
        case .countdown(let end):
            Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: Expanded island

private struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var media: MediaService
    @ObservedObject var agents: AgentService
    @ObservedObject var battery: BatteryService
    @ObservedObject var usage: UsageService

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if model.tab == .agents {
                    AgentsTab(model: model, usage: usage)
                } else if model.tab == .system {
                    SystemTab(stats: model.ambient.system, battery: battery)
                } else if model.tab == .network {
                    NetworkTab(network: model.ambient.network)
                } else if model.tab == .settings {
                    SettingsTab(settings: model.settings, servers: model.ambient.servers)
                } else {
                    nowTab
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        // The island takes the height the content really needs.
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        .onPreferenceChange(HeightKey.self) { height in
            MainActor.assumeIsolated {
                let content = height - model.notchSize.height
                if abs(model.contentHeight - content) > 0.5 { model.contentHeight = content }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top) // min 0: never centre an overflow
    }

    @ViewBuilder private var nowTab: some View {
        VStack(spacing: 10) {
            ForEach(model.visibleSessions) { session in
                SessionRow(session: session, replies: model.settings.quickReplies, agents: agents)
            }
            if model.showsMusic, let track = media.track {
                MusicCard(track: track, media: media)
            }
            if model.visibleSessions.isEmpty && !model.showsMusic {
                IdleCard(model: model, media: media, agents: agents)
            }
            TimerRow(timer: model.ambient.timer)
            ShelfRow(shelf: model.ambient.shelf)
            InfoStrip(calendar: model.ambient.calendar, servers: model.ambient.servers)
        }
    }

    /// Tabs on the left of the notch, context controls on the right.
    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                TabButton(title: "Ora", selected: model.tab == .now) { model.select(.now) }
                TabButton(title: "Agenti", selected: model.tab == .agents, badge: usage.isUrgent) { model.select(.agents) }
                TabButton(title: "Rete", selected: model.tab == .network) { model.select(.network) }
                TabButton(title: "Sistema", selected: model.tab == .system) { model.select(.system) }
            }
            Spacer(minLength: model.notchSize.width + 12)
            if model.tab == .agents {
                ControlButton(symbol: "arrow.clockwise", size: 11) { usage.refresh(force: true) }
                    .opacity(usage.isRefreshing ? 0.4 : 1)
                    .help("Aggiorna")
                Menu {
                    ForEach(AgentName.allCases, id: \.self) { agent in
                        Button("Nuova sessione \(agent.displayName)") { AgentLauncher.launch(agent) }
                    }
                } label: {
                    Image(systemName: "apple.terminal")
                        .font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Avvia un agente")
            } else if battery.hasBattery {
                BatteryLabel(battery: battery)
            }
            ControlButton(symbol: "gearshape.fill", size: 11) { model.select(model.tab == .settings ? .now : .settings) }
                .opacity(model.tab == .settings ? 1 : 0.6)
                .help("Impostazioni")
        }
        .padding(.horizontal, 18)
        .frame(height: model.notchSize.height)
        .foregroundStyle(.white)
    }
}

private struct TabButton: View {
    let title: String
    let selected: Bool
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold))
                if badge { Circle().fill(.red).frame(width: 5, height: 5) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
            .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: "Ora" tab

private struct SessionRow: View {
    let session: AgentSession
    let replies: [String]
    @ObservedObject var agents: AgentService

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(session.state.color.opacity(0.16))
                StateIcon(state: session.state, size: 13)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project)
                    .font(.system(size: 12, weight: .semibold))
                Text(session.summary
                     ?? [session.agent.displayName, session.state.title, session.tool].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryText)
                    .lineLimit(session.summary == nil ? 1 : 2)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if session.requestID != nil {
                PillButton(title: "Nega", color: .white.opacity(0.18)) { agents.decide(session, allow: false) }
                PillButton(title: "Consenti", color: .orange) { agents.decide(session, allow: true) }
            } else if agents.canReply(to: session) {
                Menu {
                    ForEach(replies, id: \.self) { reply in
                        Button(reply) { agents.reply(reply, to: session) }
                    }
                } label: {
                    Text("Rispondi").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.18)))
                .help("Scrivi nel terminale di questa sessione")
            } else if agents.canInterrupt(session) {
                PillButton(title: "Interrompi", color: .white.opacity(0.18)) { agents.interrupt(session) }
                    .help("Preme Esc nel terminale: ferma il turno in corso")
            } else if session.state == .working {
                Text(session.startedAt, style: .relative)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
                    .frame(maxWidth: 70, alignment: .trailing)
            } else {
                Ago(date: session.updatedAt)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            if session.state == .completed || session.state == .failed {
                ControlButton(symbol: "xmark", size: 10) { agents.dismiss(session) }
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { agents.activate(session) }
        .help("Vai al terminale")
    }
}

private struct MusicCard: View {
    let track: Track
    @ObservedObject var media: MediaService

    var body: some View {
        let tint = Color(nsColor: media.tint)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Artwork(image: media.artwork, size: 54, corner: 10)
                    .onTapGesture { media.openPlayer() }
                    .help("Apri il player")
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(track.artist.isEmpty ? " " : track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 18) {
                    ControlButton(symbol: "backward.fill", size: 14) { media.previous() }
                    ControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 20) { media.togglePlayPause() }
                    ControlButton(symbol: "forward.fill", size: 14) { media.next() }
                }
            }
            ProgressRow(track: track, tint: tint) { media.seek(toFraction: $0) }
        }
        .foregroundStyle(.white)
    }
}

private struct ProgressRow: View {
    let track: Track
    let tint: Color
    let onSeek: (Double) -> Void
    @StateObject private var drag = Box<Double?>(nil)

    var body: some View {
        // Refreshes only while the island is expanded and the track plays.
        TimelineView(.periodic(from: .now, by: track.isPlaying ? 0.5 : 3600)) { context in
            let position = track.position(at: context.date)
            let fraction = drag.value ?? (track.duration > 0 ? position / track.duration : 0)
            HStack(spacing: 8) {
                Text(format(drag.value.map { $0 * track.duration } ?? position))
                GeometryReader { geometry in
                    LevelBar(value: fraction, color: tint)
                        .frame(height: 4)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { drag.value = clamp($0.location.x / geometry.size.width) }
                            .onEnded {
                                onSeek(clamp($0.location.x / geometry.size.width))
                                drag.value = nil
                            })
                }
                .frame(height: 14)
                .disabled(track.duration <= 0)
                Text(track.duration > 0 ? format(track.duration) : "--:--")
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())
            .foregroundStyle(secondaryText)
        }
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let total = Int(seconds)
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Nothing live: resume the last track, start an agent, see the last finished job.
private struct IdleCard: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var media: MediaService
    @ObservedObject var agents: AgentService

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if model.settings.music, let track = media.lastTrack {
                    Artwork(image: media.lastArtwork, size: 30, corner: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title).font(.system(size: 12, weight: .semibold))
                        Text(track.artist.isEmpty ? "Ultimo brano" : track.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryText)
                    }
                    .lineLimit(1)
                    ControlButton(symbol: "play.fill", size: 14) { media.resumeLast() }
                        .help("Riprendi")
                }
                Spacer(minLength: 8)
                ForEach(AgentName.allCases, id: \.self) { agent in
                    PillButton(title: agent == .claude ? "Claude" : "Codex", color: .white.opacity(0.18)) {
                        AgentLauncher.launch(agent)
                    }
                    .help("Nuova sessione \(agent.displayName)")
                }
            }
            if model.settings.agentSessions, let last = agents.lastFinished {
                HStack(spacing: 10) {
                    StateIcon(state: last.state, size: 11)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text("\(last.agent.displayName) · \(last.project) ·")
                            Ago(date: last.updatedAt)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        Text(last.summary ?? last.state.title)
                            .font(.system(size: 11))
                            .foregroundStyle(secondaryText)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { AgentLauncher.focus(tty: last.tty, appBundleID: last.appBundleID) }
                .help("Vai al terminale")
            }
        }
        .foregroundStyle(.white)
    }
}

/// "ora", "3 min fa", "2 h fa": refreshed once a minute, no ticking seconds.
private struct Ago: View {
    let date: Date

    var body: some View {
        TimelineView(.everyMinute) { context in
            let minutes = Int(context.date.timeIntervalSince(date) / 60)
            Text(minutes < 1 ? "ora" : minutes < 60 ? "\(minutes) min fa" : "\(minutes / 60) h fa")
                .lineLimit(1)
        }
    }
}

// MARK: Settings tab

private struct SettingsTab: View {
    @ObservedObject var settings: Settings
    @ObservedObject var servers: ServerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ToggleChip(title: "Musica", isOn: settings.music) { settings.music.toggle() }
                ToggleChip(title: "Batteria", isOn: settings.battery) { settings.battery.toggle() }
                ToggleChip(title: "HUD volume", isOn: settings.volumeHUD) { settings.volumeHUD.toggle() }
                ToggleChip(title: "Sessioni agenti", isOn: settings.agentSessions) { settings.agentSessions.toggle() }
                ToggleChip(title: "Limiti agenti", isOn: settings.agentLimits) { settings.agentLimits.toggle() }
                ToggleChip(title: "Permessi dal notch", isOn: settings.approveFromNotch) { settings.approveFromNotch.toggle() }
                ToggleChip(title: "Suoni avvisi", isOn: settings.agentSounds) { settings.agentSounds.toggle() }
                ToggleChip(title: "Calendario", isOn: settings.calendar) { settings.calendar.toggle() }
                ToggleChip(title: "Mic e camera", isOn: settings.privacyDots) { settings.privacyDots.toggle() }
                ToggleChip(title: "Avvio al login", isOn: SettingsActions.launchesAtLogin) {
                    SettingsActions.toggleLaunchAtLogin()
                    settings.objectWillChange.send()
                }
                let hooks = AgentHooks.isInstalled()
                ToggleChip(title: "Hook agenti", isOn: hooks) {
                    SettingsActions.toggleHooks(installed: hooks)
                    settings.objectWillChange.send()
                }
                .help("Collega Claude Code e Codex al notch")
            }

            Section(title: "Server locali", add: SettingsActions.addServer) {
                ForEach(servers.servers) { server in
                    Chip(title: server.name, dot: server.isUp == nil ? .gray : server.isUp! ? .green : .red,
                         help: server.url.absoluteString) { servers.remove(server.name) }
                }
            }
            Section(title: "Risposte rapide", add: { SettingsActions.addReply(to: settings) }) {
                ForEach(settings.quickReplies, id: \.self) { reply in
                    Chip(title: reply, dot: nil, help: reply) { settings.quickReplies.removeAll { $0 == reply } }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private struct Section<Content: View>: View {
        let title: String
        let add: () -> Void
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(secondaryText)
                    Spacer()
                    ControlButton(symbol: "plus", size: 9, action: add).help("Aggiungi")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                    content
                }
            }
        }
    }
}

private struct ToggleChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.green : secondaryText)
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A removable entry: server (with its state dot) or quick reply.
private struct Chip: View {
    let title: String
    let dot: Color?
    let help: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(secondaryText)
                .help("Rimuovi")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.08)))
        .help(help)
    }
}

private struct BatteryLabel: View {
    @ObservedObject var battery: BatteryService

    var body: some View {
        HStack(spacing: 5) {
            Text("\(battery.level)%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(battery.isPluggedIn ? .green : (battery.level <= 20 ? .red : .white))
        }
    }

    private var symbol: String {
        if battery.isPluggedIn { return "battery.100.bolt" }
        switch battery.level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: "Rete" tab (Omarchy-style network panel)

private struct NetworkTab: View {
    @ObservedObject var network: NetworkService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: network.interface == nil ? "wifi.slash" : network.isTunnel ? "lock.shield"
                      : network.wifi != nil ? "wifi" : "cable.connector")
                    .font(.system(size: 12, weight: .semibold))
                Text(network.interface == nil ? "Non connesso" : network.isTunnel ? (network.wifi != nil ? "VPN su Wi-Fi" : "VPN")
                     : network.wifi != nil ? "Wi-Fi" : "Ethernet")
                    .font(.system(size: 12, weight: .semibold))
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(secondaryText) }
                Spacer()
                if let name = network.interface {
                    Text(name).font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                pair("Ping", ping(network.internetPing), "Router", network.isTunnel ? "--" : ping(network.routerPing))
                pair("Ricezione", network.downRate.map { bytes($0) + "/s" } ?? "--",
                     "Invio", network.upRate.map { bytes($0) + "/s" } ?? "--")
                pair("Scaricati", network.received > 0 ? bytes(Double(network.received)) : "--",
                     "Caricati", network.sent > 0 ? bytes(Double(network.sent)) : "--")
                pair("Indirizzo IP", network.ip ?? "--", "Gateway", network.gateway ?? "--")
            }
            HStack(spacing: 8) {
                PillButton(title: network.isTesting ? "Test in corso…" : "Test velocità", color: .white.opacity(0.14)) {
                    network.speedTest()
                }
                .disabled(network.isTesting)
                if let speed = network.speed {
                    Text("↓ \(mbit(speed.down))  ↑ \(mbit(speed.up))  ·  \(Int(speed.latency)) ms")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(secondaryText)
                }
            }
            if let tailnet = network.tailnet {
                TailnetList(ip: tailnet.ip, peers: tailnet.peers)
            }
        }
        .foregroundStyle(.white)
        .onAppear { network.start() }
        .onDisappear { network.stop() }
    }

    private var detail: String? {
        guard let wifi = network.wifi else { return nil }
        return [wifi.band, "\(Int(wifi.rate)) Mbit/s", "\(wifi.rssi) dBm"].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func pair(_ a: String, _ av: String, _ b: String, _ bv: String) -> some View {
        GridRow {
            Text(a).foregroundStyle(secondaryText)
            Text(av).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            Text(b).foregroundStyle(secondaryText)
            Text(bv).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private func ping(_ ping: Ping) -> String {
        guard let ms = ping.ms else { return ping.loss == 100 ? "nessuna risposta" : "--" }
        let value = ms < 10 ? String(format: "%.1f ms", ms) : "\(Int(ms.rounded())) ms"
        if let loss = ping.loss, loss > 0 { return value + " · \(Int(loss))% persi" }
        return value
    }

    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal)
    }

    private func mbit(_ bits: Double) -> String { "\(Int((bits / 1_000_000).rounded())) Mbit/s" }
}

/// Tailscale machines: a click copies the IP, the terminal button opens `ssh`.
private struct TailnetList: View {
    let ip: String
    let peers: [TailnetPeer]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Tailscale").font(.system(size: 12, weight: .semibold))
                Text(ip.isEmpty ? "spento" : ip).font(.system(size: 11).monospacedDigit()).foregroundStyle(secondaryText)
                Spacer()
            }
            ForEach(peers.prefix(8)) { peer in
                HStack(spacing: 7) {
                    Circle().fill(peer.online ? Color.green : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                    Text(peer.name).lineLimit(1)
                    Spacer()
                    Text(peer.ip).monospacedDigit().foregroundStyle(secondaryText)
                    Button { AgentLauncher.open("ssh \(peer.host)") } label: {
                        Image(systemName: "apple.terminal").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(!peer.online)
                    .opacity(peer.online ? 0.8 : 0.25)
                    .help("ssh \(peer.host)")
                }
                .font(.system(size: 11))
                .opacity(peer.online ? 1 : 0.5)
                .contentShape(Rectangle())
                .onTapGesture {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(peer.ip, forType: .string)
                }
                .help("Clic per copiare l'IP")
            }
        }
    }
}

// MARK: "Sistema" tab (Omarchy-style power panel)

private struct SystemTab: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var battery: BatteryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            meter("CPU", stats.cpu ?? 0, stats.cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "--")
            let memory = Double(stats.memoryUsed) / Double(max(stats.memoryTotal, 1))
            meter("Memoria", memory, "\(gigabytes(stats.memoryUsed)) di \(gigabytes(stats.memoryTotal))")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                pair("Batteria", "\(battery.level)%" + (battery.isPluggedIn ? " · in carica" : ""),
                     battery.isPluggedIn ? "Alla carica" : "Autonomia", stats.minutesLeft.map(duration) ?? "--")
                pair("Consumo", stats.watts.map { String(format: "%.1f W", $0) } ?? "--",
                     "Salute", stats.health.map { "\($0)%" } ?? "--")
                pair("Cicli", stats.cycles.map(String.init) ?? "--", "Temperatura", thermal)
            }
            if !stats.outputs.isEmpty {
                HStack(spacing: 10) {
                    Text("Uscita audio").foregroundStyle(secondaryText)
                    Menu {
                        ForEach(stats.outputs) { device in
                            Button { stats.selectOutput(device.id) } label: {
                                if device.id == stats.output { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                            Text(stats.outputs.first { $0.id == stats.output }?.name ?? "--").lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    Spacer()
                }
                .font(.system(size: 11))
            }
        }
        .foregroundStyle(.white)
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    private func meter(_ title: String, _ value: Double, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(title).foregroundStyle(secondaryText).frame(width: 70, alignment: .leading)
            LevelBar(value: value, color: meterColor(value)).frame(height: 6)
            Text(text).monospacedDigit().frame(width: 110, alignment: .trailing)
        }
        .font(.system(size: 11))
    }

    private func pair(_ a: String, _ av: String, _ b: String, _ bv: String) -> some View {
        GridRow {
            Text(a).foregroundStyle(secondaryText)
            Text(av).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            Text(b).foregroundStyle(secondaryText)
            Text(bv).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var thermal: String {
        switch stats.thermal {
        case .nominal: "normale"
        case .fair: "calda"
        case .serious: "molto calda"
        case .critical: "critica"
        @unknown default: "--"
        }
    }

    private func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
    private func duration(_ minutes: Int) -> String { "\(minutes / 60) h \(minutes % 60) min" }
}

// MARK: Timer row ("Ora" tab)

private struct TimerRow: View {
    @ObservedObject var timer: TimerService

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange)
            if let end = timer.endsAt {
                Text(timer.label.isEmpty ? "Timer" : timer.label).lineLimit(1)
                Spacer()
                Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                    .monospacedDigit()
                    .frame(width: 60, alignment: .trailing)
                Button { timer.cancel() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(secondaryText)
                    .help("Annulla")
            } else {
                Text("Timer").foregroundStyle(secondaryText)
                Spacer()
                ForEach([5, 15, 25], id: \.self) { minutes in
                    PillButton(title: "\(minutes) min", color: .white.opacity(0.1)) { timer.start(minutes: Double(minutes), label: "") }
                }
                PillButton(title: "Promemoria…", color: .white.opacity(0.1)) { SettingsActions.addTimer(to: timer) }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
    }
}

// MARK: "Agenti" tab (Omarchy-style usage panel)

private struct AgentsTab: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var usage: UsageService

    var body: some View {
        VStack(spacing: 10) {
            HeroLine(stats: usage.stats)
            ForEach(model.agentsShown, id: \.self) { id in
                AgentLimitsBlock(id: id, info: usage.usage[id], stats: usage.stats[id])
            }
            if model.agentsShown.isEmpty {
                Text(usage.isRefreshing ? "Lettura dei limiti…" : "Nessun agente rilevato")
                    .font(.system(size: 12))
                    .foregroundStyle(secondaryText)
            }
        }
        .foregroundStyle(.white)
    }
}

/// Rotates through what the token counts add up to, like Omarchy's hero line.
private struct HeroLine: View {
    let stats: [String: LocalStats]

    var body: some View {
        let lines = facts
        TimelineView(.periodic(from: .now, by: 4)) { context in
            let index = lines.isEmpty ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 4) % lines.count
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                Text(lines.isEmpty ? "Nessun utilizzo negli ultimi 7 giorni" : lines[index])
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .id(index)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
            .animation(.easeInOut(duration: 0.3), value: index)
        }
    }

    private var facts: [String] {
        let all = Array(stats.values)
        guard !all.isEmpty else { return [] }
        let today = all.reduce(0) { $0 + $1.tokensToday }
        let week = all.reduce(0) { $0 + $1.tokensWeek }
        let prompts = all.reduce(0) { $0 + $1.promptsToday }
        let sessions = all.reduce(0) { $0 + $1.sessionsToday }
        var lines = ["Oggi \(compactNumber(today)) token · settimana \(compactNumber(week))"]
        if prompts > 0 { lines.append("Oggi \(prompts) prompt in \(sessions) session\(sessions == 1 ? "e" : "i")") }
        if let top = all.max(by: { $0.tokensWeek < $1.tokensWeek })?.topModel {
            lines.append("Modello più usato: \(top)")
        }
        if let busiest = all.compactMap(\.busiestDay).max() {
            lines.append("Giorno più intenso: \(busiest.formatted(.dateTime.weekday(.wide).day().month()))")
        }
        return lines
    }
}

private struct AgentLimitsBlock: View {
    let id: String
    let info: AgentUsage?
    let stats: LocalStats?

    private func statsLine(_ stats: LocalStats) -> String {
        var parts = ["Oggi \(compactNumber(stats.tokensToday)) token"]
        if stats.promptsToday > 0 { parts.append("\(stats.promptsToday) prompt") }
        parts.append("settimana \(compactNumber(stats.tokensWeek))")
        if let model = stats.topModel { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ProviderMark(id: id, size: 15)
                Text(Collectors.collector(id)?.displayName ?? id).font(.system(size: 12, weight: .semibold))
                if let plan = info?.plan {
                    Text(plan).font(.system(size: 11)).foregroundStyle(secondaryText)
                }
                Spacer()
                if let fetched = info?.fetchedAt {
                    Ago(date: fetched)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.35))
                        .help("Ultimo aggiornamento")
                }
            }
            .frame(height: 20)

            if let stats, !stats.isEmpty {
                Text(statsLine(stats))
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                    .frame(height: 16)
            }

            ForEach(info?.limits ?? []) { limit in
                LimitRow(limit: limit)
                    .frame(height: 20)
            }

            if let balance = info?.balance {
                HStack {
                    Text("Credito residuo")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Text(balance)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                .frame(height: 20)
            }

            if let line = info?.note ?? info?.extra {
                HStack(spacing: 4) {
                    Image(systemName: info?.note != nil ? "info.circle" : "gift")
                    Text(line).lineLimit(1)
                }
                .font(.system(size: 10))
                .foregroundStyle(info?.note != nil ? .orange.opacity(0.9) : secondaryText)
                .frame(height: 16)
            }
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit

    var body: some View {
        HStack(spacing: 8) {
            Text(limit.label)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            LevelBar(value: limit.percent, color: meterColor(limit.percent))
                .frame(height: 5)
            Text("\(Int((limit.percent * 100).rounded(.down)))%")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            Text(limit.runsOutAt.map(runOutText) ?? resetText)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(limit.runsOutAt == nil ? .white.opacity(0.4) : .orange)
                .frame(width: 74, alignment: .trailing)
                .help(limit.runsOutAt == nil ? "Si azzera" : "A questo ritmo si esaurisce prima del reset (\(resetText))")
        }
    }

    private func runOutText(_ date: Date) -> String {
        let style: Date.FormatStyle = Calendar.current.isDateInToday(date)
            ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).hour().minute()
        return "finisce \(date.formatted(style))"
    }

    private var resetText: String {
        guard let reset = limit.resetsAt else { return "" }
        let seconds = Int(reset.timeIntervalSinceNow)
        guard seconds > 0 else { return "azzerato" }
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "tra \(days)g \(hours)h" }
        if hours > 0 { return "tra \(hours)h \(minutes)m" }
        return "tra \(max(minutes, 1))m"
    }
}

// MARK: File shelf

/// Files parked on the notch: drag out to use, click to open, right-click to remove.
private struct ShelfRow: View {
    @ObservedObject var shelf: Shelf

    var body: some View {
        if !shelf.files.isEmpty {
            HStack(spacing: 6) {
                ForEach(shelf.files.prefix(4), id: \.self) { url in
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(url.lastPathComponent).lineLimit(1).frame(maxWidth: 90)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .onDrag { NSItemProvider(object: url as NSURL) }
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .contextMenu {
                        Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Rimuovi dal ripiano") { shelf.remove(url) }
                    }
                    .help(url.path)
                }
                if shelf.files.count > 4 {
                    Text("+\(shelf.files.count - 4)").foregroundStyle(secondaryText)
                        .help(shelf.files.dropFirst(4).map(\.lastPathComponent).joined(separator: "\n"))
                }
                Spacer(minLength: 0)
                ControlButton(symbol: "xmark", size: 10) { shelf.clear() }
                    .help("Svuota il ripiano")
            }
            .font(.system(size: 11))
            .foregroundStyle(.white)
        }
    }
}

// MARK: Calendar, servers, privacy

/// One line under the "Ora" tab: next event on the left, model servers on the right.
private struct InfoStrip: View {
    @ObservedObject var calendar: CalendarService
    @ObservedObject var servers: ServerMonitor

    var body: some View {
        if calendar.next != nil || !servers.servers.isEmpty {
            HStack(spacing: 10) {
                if let event = calendar.next {
                    Circle().fill(Color(nsColor: event.color)).frame(width: 7, height: 7)
                    TimelineView(.everyMinute) { context in
                        Text("\(when(event, now: context.date)) · \(event.title)")
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                ForEach(servers.servers) { server in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(server.isUp == nil ? Color.gray : server.isUp! ? .green : .red)
                            .frame(width: 6, height: 6)
                        Text(server.name)
                    }
                    .help(server.url.absoluteString)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private func when(_ event: UpcomingEvent, now: Date) -> String {
        if event.start <= now { return "In corso fino alle \(event.end.formatted(.dateTime.hour().minute()))" }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        return minutes < 60 ? "Tra \(max(minutes, 1)) min" : "Alle \(event.start.formatted(.dateTime.hour().minute()))"
    }
}

/// Orange dot while the microphone is in use, green for the camera.
private struct PrivacyDots: View {
    @ObservedObject var privacy: PrivacyMonitor

    var body: some View {
        HStack(spacing: 3) {
            if privacy.microphone { Circle().fill(.orange).frame(width: 6, height: 6).help("Microfono in uso") }
            if privacy.camera { Circle().fill(.green).frame(width: 6, height: 6).help("Fotocamera in uso") }
        }
    }
}

// MARK: Small components

private struct PillButton: View {
    let title: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// View-local mutable state. Stands in for @State, whose macro plugin is not
/// shipped with the Command Line Tools toolchain.
final class Box<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

/// AppKit spinner: animated by Core Animation, nearly free on the CPU.
private struct Spinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.appearance = NSAppearance(named: .darkAqua)
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ nsView: NSProgressIndicator, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSProgressIndicator, context: Context) -> CGSize? {
        CGSize(width: 14, height: 14)
    }
}

private struct StateIcon: View {
    let state: AgentState
    let size: CGFloat

    var body: some View {
        switch state {
        case .working:
            Spinner()
        case .approval:
            // Pulses like Omarchy's "needs input" badge (2 updates per second).
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                symbol.opacity(on ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.6), value: on)
            }
        default:
            symbol
        }
    }

    private var symbol: some View {
        Image(systemName: state.symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(state.color)
    }
}

/// Mark for any provider: Claude and Codex keep their own look, the others
/// use their collector's SF Symbol.
private struct ProviderMark: View {
    let id: String
    let size: CGFloat

    var body: some View {
        switch id {
        case "claude": AgentMark(agent: .claude, size: size)
        case "codex": AgentMark(agent: .codex, size: size)
        default:
            Image(systemName: Collectors.collector(id)?.symbol ?? "sparkles")
                .font(.system(size: size * 0.62, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.15)))
        }
    }
}

private struct AgentMark: View {
    let agent: AgentName
    let size: CGFloat

    var body: some View {
        switch agent {
        case .claude:
            Image(systemName: "asterisk")
                .font(.system(size: size * 0.75, weight: .heavy))
                .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                .frame(width: size, height: size)
        case .codex:
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.15)))
        }
    }
}

private struct Artwork: View {
    let image: NSImage?
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: max(size, 1), height: max(size, 1))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @StateObject private var hover = Box(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 14)
                .background(Circle().fill(.white.opacity(hover.value ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onHover { hover.value = $0 }
    }
}

private struct LevelBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(color)
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
    }
}

private struct Equalizer: View {
    let color: Color

    var body: some View {
        // 4 updates per second: lively enough, almost free on the CPU.
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 4 + 10 * abs(sin(t * (1.6 + Double(index) * 0.55) + Double(index))))
                }
            }
            .frame(height: 14)
        }
    }
}

// MARK: Presentation helpers

private func meterColor(_ percent: Double) -> Color {
    percent >= UsageService.urgentThreshold ? .red : percent >= 0.7 ? .yellow : .green
}

private func compactNumber(_ value: Int) -> String {
    switch value {
    case 1_000_000_000...: String(format: "%.1f Mld", Double(value) / 1e9)
    case 1_000_000...: String(format: "%.1f M", Double(value) / 1e6)
    case 1_000...: String(format: "%.0f k", Double(value) / 1e3)
    default: "\(value)"
    }
}

private extension AgentState {
    var color: Color {
        switch self {
        case .working: .white
        case .approval: .orange
        case .waiting: .cyan
        case .completed: .green
        case .failed: .red
        }
    }

    var symbol: String {
        switch self {
        case .working: "circle.dotted"
        case .approval: "exclamationmark"
        case .waiting: "ellipsis.bubble.fill"
        case .completed: "checkmark"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var shortLabel: String {
        switch self {
        case .working: "Lavora"
        case .approval: "Approva"
        case .waiting: "Attende"
        case .completed: "Fatto"
        case .failed: "Errore"
        }
    }

    var title: String {
        switch self {
        case .working: "al lavoro"
        case .approval: "chiede un permesso"
        case .waiting: "ti aspetta"
        case .completed: "ha finito"
        case .failed: "fermo per un errore"
        }
    }
}

private extension HUD {
    var symbol: String {
        switch self {
        case .volume(let level, let muted):
            if muted || level == 0 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        case .charging(_, let plugged): return plugged ? "bolt.fill" : "powerplug"
        case .lowBattery: return "battery.25"
        case .usage: return "gauge.with.dots.needle.67percent"
        case .timer: return "bell.fill"
        }
    }

    var color: Color {
        switch self {
        case .volume: .white
        case .charging(_, let plugged): plugged ? .green : .white
        case .lowBattery: .red
        case .usage(_, let percent): meterColor(percent)
        case .timer: .orange
        }
    }
}
