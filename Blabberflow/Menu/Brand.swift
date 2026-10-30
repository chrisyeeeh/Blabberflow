import AppKit
import SwiftUI

/// The app icon's colours, so the menu bar surfaces match it.
enum Brand {
    static let gradientTop = Color(.displayP3, red: 0.42, green: 0.36, blue: 1.00)
    static let gradientBottom = Color(.displayP3, red: 0.20, green: 0.10, blue: 0.62)

    static let gradient = LinearGradient(colors: [gradientTop, gradientBottom], startPoint: .top, endPoint: .bottom)

    /// The app icon at menu bar size, shown while idle.
    static let menuBarIcon: NSImage = {
        let icon = NSApp.applicationIconImage.copy() as! NSImage
        icon.size = NSSize(width: 18, height: 18)
        return icon
    }()

    /// A tiny version of the pill, shown in the menu bar while listening.
    static let menuBarPill: NSImage = {
        let renderer = ImageRenderer(content: MenuBarPillGlyph())
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = false
        return image
    }()
}

private struct MenuBarPillGlyph: View {
    private let heights: [CGFloat] = [3, 6, 9, 6, 3]

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.red)
                .frame(width: 4, height: 4)
            HStack(spacing: 1.5) {
                ForEach(heights.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: 1.5, height: heights[index])
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 14)
        .background(Brand.gradient, in: .capsule)
        .padding(.vertical, 2)
    }
}
