#if DEBUG
import AppKit
import SwiftUI

/// `NotchLite --render-previews <dir>` (debug builds only): renders island states to PNG.
@MainActor
enum DebugPreviews {
    static func render(to directory: String) {
        let settings = Settings()
        let media = MediaService(), agents = AgentService(), battery = BatteryService(), usage = UsageService()
        let model = IslandModel(settings: settings, media: media, agents: agents, battery: battery, usage: usage, ambient: Ambient())
        model.notchSize = CGSize(width: 185, height: 38)
        let art = NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            NSGradient(colors: [.systemPink, .systemPurple])?.draw(in: rect, angle: 45); return true
        }
        let track = Track(title: "Midnight City", artist: "M83", duration: 243, elapsed: 81,
                          timestamp: Date(), rate: 1, isPlaying: true, bundleID: nil)

        func snap(_ name: String) {
            let view = IslandRootView(model: model)
                .frame(width: 680, height: 360).background(Color(white: 0.85))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
        let now = Date().timeIntervalSince1970

        media.debugSet(track: track, artwork: art, tint: .systemPink)
        agents.debugInject(["agent": "claude", "kind": "working", "session": "a", "cwd": "/Users/x/NotchLite", "ts": now])
        snap("1-compact-music-working")
        agents.debugInject(["agent": "codex", "kind": "working", "session": "b", "cwd": "/Users/x/website", "ts": now])
        model.debugSetExpanded(true)
        snap("2-expanded-now")
        agents.debugInject(["agent": "claude", "kind": "approval", "session": "a", "cwd": "/Users/x/NotchLite", "tool": "Bash",
                            "req": "1-1", "ts": now])
        let payload = AgentService.directory.appendingPathComponent("payloads/preview.json")
        try? FileManager.default.createDirectory(at: payload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"last_assistant_message":"Ho sistemato il layout della scheda Agenti e aggiunto i test. Tutto compila senza avvisi."}"#
            .write(to: payload, atomically: true, encoding: .utf8)
        agents.debugInject(["agent": "codex", "kind": "completed", "session": "b", "cwd": "/Users/x/website",
                            "payload": payload.path, "ts": now])
        snap("2b-expanded-approve-summary")
        model.debugSetExpanded(false)
        snap("3-compact-approval")
        model.debugSetExpanded(true)
        model.tab = .agents
        usage.debugSet(
            usage: [
                "claude": AgentUsage(plan: "Max 5x", limits: [
                    UsageLimit(label: "Sessione (5 ore)", percent: 0.06, resetsAt: Date().addingTimeInterval(7000)),
                    UsageLimit(label: "Settimana", percent: 0.93, resetsAt: Date().addingTimeInterval(500_000)),
                ], fetchedAt: Date()),
                "codex": AgentUsage(plan: "Pro", limits: [
                    UsageLimit(label: "Settimana", percent: 0.23, resetsAt: Date().addingTimeInterval(390_000)),
                ], extra: "1 reset gratuito disponibile", fetchedAt: Date()),
                "openrouter": AgentUsage(limits: [
                    UsageLimit(label: "Limite chiave", percent: 0.41, resetsAt: nil),
                ], balance: "12,40 $", fetchedAt: Date()),
            ],
            stats: ["claude": LocalStats(tokensToday: 4_200_000, tokensWeek: 31_000_000, promptsToday: 42, sessionsToday: 6, topModel: "claude-opus-5-5")]
        )
        snap("4-expanded-agents")
        model.debugSetExpanded(false)
        agents.debugInject(["agent": "claude", "kind": "end", "session": "a", "ts": now])
        agents.debugInject(["agent": "codex", "kind": "end", "session": "b", "ts": now])
        model.show(.usage(agent: "Claude Code", percent: 0.93))
        snap("5-compact-usage-alert")
        media.debugSet(track: nil, artwork: nil, tint: .white)
        model.tab = .now
        model.debugSetExpanded(true)
        snap("6-expanded-idle")
        model.tab = .settings
        snap("7-expanded-settings")
        model.tab = .network
        model.ambient.network.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        snap("8-expanded-network")
        model.tab = .system
        model.ambient.system.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        snap("9-expanded-system")
        model.ambient.timer.start(minutes: 25, label: "Togli la pasta")
        model.tab = .now
        snap("10-expanded-timer")
        model.debugSetExpanded(false)
        snap("11-compact-timer")
        model.show(.timer(label: "Togli la pasta"))
        snap("12-compact-timer-done")
        model.ambient.timer.cancel()
    }

    /// `--render-live <dir>`: same views, real limits and stats from this Mac.
    static func renderLive(to directory: String) {
        let settings = Settings()
        let media = MediaService(), agents = AgentService(), battery = BatteryService(), usage = UsageService()
        let ambient = Ambient()
        let model = IslandModel(settings: settings, media: media, agents: agents, battery: battery, usage: usage, ambient: ambient)
        model.notchSize = CGSize(width: 185, height: 38)
        battery.start()
        ambient.servers.start()
        ambient.shelf.add([URL(fileURLWithPath: "README.md").standardizedFileURL, URL(fileURLWithPath: "Package.swift").standardizedFileURL])
        usage.refresh(force: true)
        let deadline = Date().addingTimeInterval(30)
        while usage.isRefreshing, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let size = { model.size }
        func snap(_ name: String) {
            // First pass lets the content report its height, second one draws it.
            _ = ImageRenderer(content: IslandRootView(model: model).frame(width: 680, height: 560)).nsImage
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let view = IslandRootView(model: model)
                .frame(width: 680, height: size().height + 40).background(Color(white: 0.85))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
        model.debugSetExpanded(true)
        model.tab = .agents
        snap("live-agents")
        model.tab = .now
        snap("live-now")
        model.debugSetExpanded(false)
        model.show(.charging(level: battery.level, plugged: battery.isPluggedIn))
        snap("live-compact")
    }
}
#endif
