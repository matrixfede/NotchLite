import AppKit
import SwiftUI

/// Welcome guide: shown at launch until "Non mostrare più" is ticked,
/// and on demand from the settings tab.
@MainActor
enum Guide {
    private static let key = "guideHidden"
    private static var window: NSWindow?
    private static var observer: NSObjectProtocol?

    static func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: key) { show() }
    }

    static func show() {
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let hide = Box(UserDefaults.standard.bool(forKey: key))
        let hosting = NSHostingView(rootView: GuideView(hide: hide) { window?.close() })
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = hosting
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(hide.value, forKey: key)
                if let observer { NotificationCenter.default.removeObserver(observer) }
                Guide.window = nil
            }
        }
        return window
    }
}

struct GuideView: View {
    @ObservedObject var hide: Box<Bool>
    let close: () -> Void

    private static let features: [(symbol: String, color: Color, title: String, text: String)] = [
        ("music.note", .pink, "Musica", "Brano, copertina e controlli da qualsiasi app o browser."),
        ("sparkles", .orange, "Agenti", "Sessioni di Claude Code e Codex, permessi e limiti del piano."),
        ("network", .blue, "Rete", "Ping, traffico, IP, test di velocità e Tailscale."),
        ("cpu", .green, "Sistema", "CPU, memoria, batteria e uscita audio."),
        ("timer", .yellow, "Timer", "Conto alla rovescia e promemoria sul notch chiuso."),
        ("tray.and.arrow.down.fill", .purple, "Ripiano", "Trascina file sul notch e riprendili quando vuoi."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            NotchDemo()
                .frame(height: 70)

            VStack(spacing: 6) {
                Text("Benvenuto in NotchLite")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Il notch del tuo Mac, finalmente utile.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(Self.features, id: \.title) { feature in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: feature.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(feature.color)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(feature.color.opacity(0.16)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.title).font(.system(size: 12, weight: .semibold))
                            Text(feature.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06)))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                tip("cursorarrow.rays", "Fermati sul notch per mezzo secondo, o fai clic, per aprirlo.")
                tip("gearshape.fill", "Impostazioni dall'ingranaggio: attiva Hook agenti per vedere Claude Code e Codex.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button { hide.value.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: hide.value ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(hide.value ? Color.green : .white.opacity(0.45))
                        Text("Non mostrare più")
                    }
                    .font(.system(size: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: close) {
                    Text("Inizia")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: 560)
        .foregroundStyle(.white)
        .background(
            ZStack {
                Color.black
                RadialGradient(colors: [.orange.opacity(0.22), .clear], center: .init(x: 0.3, y: 0), startRadius: 0, endRadius: 320)
                RadialGradient(colors: [.purple.opacity(0.22), .clear], center: .init(x: 0.75, y: 0), startRadius: 0, endRadius: 320)
            }
        )
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).frame(width: 16)
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
        }
    }
}

/// A notch that opens and closes, showing what lives in its wings.
private struct NotchDemo: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let open = (sin(t * 1.4) + 1) / 2 // 0 closed … 1 open
            let width = 150 + 150 * open
            ZStack(alignment: .top) {
                NotchShape(ear: 8, radius: 12 + 8 * open)
                    .fill(Color.black)
                    .frame(width: width, height: 30 + 30 * open)
                    .shadow(color: .orange.opacity(0.35 * open), radius: 18)
                    .overlay(
                        NotchShape(ear: 8, radius: 12 + 8 * open)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    )
                HStack {
                    Image(systemName: "music.note").foregroundStyle(.pink)
                    Spacer()
                    Image(systemName: "sparkles").foregroundStyle(.orange)
                }
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 22)
                .frame(width: width, height: 30)
                if open > 0.5 {
                    HStack(spacing: 10) {
                        Capsule().fill(.white.opacity(0.25)).frame(width: 60, height: 5)
                        Capsule().fill(.green.opacity(0.7)).frame(width: 36, height: 5)
                        Capsule().fill(.white.opacity(0.25)).frame(width: 48, height: 5)
                    }
                    .opacity((open - 0.5) * 2)
                    .offset(y: 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
