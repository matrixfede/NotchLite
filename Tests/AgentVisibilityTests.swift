import Foundation

@main
struct AgentVisibilityTests {
    @MainActor static func main() {
        let suite = "NotchLiteTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        precondition(settings.showsAgent("claude") && settings.showsAgent("cursor"))
        settings.setAgent("cursor", visible: false)
        let restored = Settings(defaults: defaults)
        precondition(!restored.showsAgent("cursor") && restored.showsAgent("claude"))
        restored.setAgent("cursor", visible: true)
        precondition(Settings(defaults: defaults).showsAgent("cursor"))
        restored.hiddenAgents = ["claude", "codex"]
        precondition(!Settings(defaults: defaults).showsAgent("codex"))
        restored.hiddenAgents.removeAll()
        precondition(Settings(defaults: defaults).showsAgent("codex"))
        print("Agent visibility persistence checks passed")
    }
}
