import AppKit
import SwiftUI

/// The app icon's colours, so the menu bar surfaces match it.
enum Brand {
    static let gradientTop = Color(.displayP3, red: 0.42, green: 0.36, blue: 1.00)
    static let gradientBottom = Color(.displayP3, red: 0.20, green: 0.10, blue: 0.62)

    static let gradient = LinearGradient(colors: [gradientTop, gradientBottom], startPoint: .top, endPoint: .bottom)

    /// Blabberflow isn't sold through the App Store, so support goes through Buy Me a Coffee.
    static let supportURL = URL(string: "https://buymeacoffee.com/Chrisyeh")!

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

/// The app icon's pill (capsule, red dot, waveform bars) drawn on a 24-unit grid, so it scales to any tile.
struct PillGlyph: View {
    /// The app icon fills the capsule with frosted white; sidebar line art outlines it.
    var filled = true

    var body: some View {
        Canvas { context, size in
            let unit = size.width / 24
            let capsule = Path(roundedRect: CGRect(x: 3 * unit, y: 8 * unit, width: 18 * unit, height: 8 * unit), cornerRadius: 4 * unit)
            if filled {
                context.fill(capsule, with: .color(.white.opacity(0.32)))
            } else {
                context.stroke(capsule, with: .color(.white), lineWidth: 2 * unit)
            }
            let dot = CGRect(x: 5.9 * unit, y: 10.6 * unit, width: 2.8 * unit, height: 2.8 * unit)
            context.fill(Path(ellipseIn: dot), with: .color(Color(red: 1, green: 0.38, blue: 0.35)))
            var bars = Path()
            for (x, height) in [(11.0, 2.0), (13.5, 4.0), (16.0, 2.4), (18.3, 1.2)] {
                bars.move(to: CGPoint(x: x * unit, y: (12 - height / 2) * unit))
                bars.addLine(to: CGPoint(x: x * unit, y: (12 + height / 2) * unit))
            }
            context.stroke(bars, with: .color(.white), style: StrokeStyle(lineWidth: 1.8 * unit, lineCap: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A small copy of the app icon: the brand gradient tile with the pill.
struct AppIconTile: View {
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Brand.gradient)
            .overlay { PillGlyph() }
            .frame(width: size, height: size)
    }
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
