import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static var appPrimaryText: Color { Color(NSColor.labelColor) }
    static var appSecondaryText: Color { Color(NSColor.secondaryLabelColor) }
    static var appTertiaryText: Color { Color(NSColor.tertiaryLabelColor) }
    static var appQuaternaryText: Color { Color(NSColor.quaternaryLabelColor) }
    static var appDivider: Color { Color(NSColor.separatorColor) }
    static var appFieldBackground: Color { Color(NSColor.controlBackgroundColor) }
    static var appFieldBorder: Color { Color(NSColor.quaternaryLabelColor) }
    static var appTrackBackground: Color { Color(NSColor.quaternaryLabelColor).opacity(0.35) }
    static var appSidebarBackground: Color { Color(NSColor.controlBackgroundColor).opacity(0.7) }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
