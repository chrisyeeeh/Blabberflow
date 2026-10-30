import AppKit
import SwiftUI

/// A borderless panel above the Dock that never takes focus from the app being dictated into.
final class PillPanel {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(
            // Room above the pill for the live preview at its tallest (about six lines).
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 210),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = FirstClickHostingView(rootView: PillView(model: model))
    }

    /// Off except while the hands-free buttons are showing, so the pill never blocks clicks on the Dock.
    var acceptsClicks: Bool {
        get { !panel.ignoresMouseEvents }
        set { panel.ignoresMouseEvents = !newValue }
    }

    /// Moves the panel to the screen under the pointer, 12 pt above the Dock.
    func show() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 12))
        panel.orderFrontRegardless()
    }
}

/// The panel never becomes key, so buttons must respond to the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
