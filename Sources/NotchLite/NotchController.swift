import AppKit
import SwiftUI

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the transparent overlay window pinned to the top of the notch screen.
/// The window ignores the mouse except while the pointer is over the island.
@MainActor
final class NotchController {
    private static let canvas = CGSize(width: 680, height: 560)

    private let model: IslandModel
    private let panel: NotchPanel
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?

    init(model: IslandModel) {
        self.model = model
        panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        // No .fullScreenAuxiliary: the island hides automatically in fullscreen spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true

        model.maxHeight = Self.canvas.height - 40 // room for the shadow
        let root = IslandRootView(model: model)
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.sizingOptions = []
        panel.contentView = hosting
    }

    func setHidden(_ hidden: Bool) {
        model.setHovering(false)
        panel.ignoresMouseEvents = true // clicks pass through until the pointer is back on the island
        hidden ? panel.orderOut(nil) : panel.orderFrontRegardless()
    }

    func start() {
        placeOnScreen()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Prefers the built-in display with a notch; otherwise draws a small
    /// virtual notch on the main display.
    private func placeOnScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first else { return } // first = the menu-bar display

        var notch = CGSize(width: 190, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        }
        if model.notchSize != notch { model.notchSize = notch }

        let frame = screen.frame
        panel.setFrame(NSRect(
            x: frame.midX - Self.canvas.width / 2,
            y: frame.maxY - Self.canvas.height,
            width: Self.canvas.width,
            height: Self.canvas.height
        ), display: true)
    }

    private var islandRect: NSRect {
        let size = model.size
        let ears = model.earRadius
        let frame = panel.frame
        return NSRect(
            x: frame.midX - size.width / 2 - ears,
            y: frame.maxY - size.height,
            width: size.width + ears * 2,
            height: size.height
        )
    }

    private func updateHover() {
        // Most moves are far below a closed island: skip the geometry work.
        if panel.ignoresMouseEvents, NSEvent.mouseLocation.y < panel.frame.maxY - model.notchSize.height - 10 { return }
        let inside = islandRect.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        model.setHovering(inside)
    }
}
