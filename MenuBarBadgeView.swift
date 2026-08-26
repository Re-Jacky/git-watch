import AppKit
import SwiftUI

final class MenuBarBadgeController {
    private let statusItem: NSStatusItem
    private let hostingView: NSHostingView<MenuBarBadgeView>

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.hostingView = NSHostingView(rootView: MenuBarBadgeView(count: 0, autoMode: false))
        guard let button = statusItem.button else { return }
        button.subviews.forEach { $0.removeFromSuperview() }
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = button.bounds
        hostingView.autoresizingMask = [.width, .height]
        button.addSubview(hostingView)
    }

    func update(count: Int, autoMode: Bool) {
        hostingView.rootView = MenuBarBadgeView(count: count, autoMode: autoMode)
        statusItem.length = hostingView.fittingSize.width
        if let button = statusItem.button {
            hostingView.frame = button.bounds
        }
    }
}

struct MenuBarBadgeView: View {
    let count: Int
    let autoMode: Bool

    private var tint: Color {
        autoMode ? Color(hex: "58A6FF") : .primary
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .fill(autoMode ? tint : Color.clear)
                        .strokeBorder(autoMode ? Color.clear : Color.primary.opacity(0.85), lineWidth: 1.25)
                )
                .foregroundColor(autoMode ? .white : .primary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(tint)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityLabel("GitWatch" + (autoMode ? ", Auto mode active" : "") + (count > 0 ? ", \(count) pull requests" : ""))
    }
}
