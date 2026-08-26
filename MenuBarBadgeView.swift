import AppKit
import SwiftUI

final class MenuBarBadgeController {
    private let statusItem: NSStatusItem
    private let hostingView: NSHostingView<MenuBarBadgeView>

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.hostingView = NSHostingView(rootView: MenuBarBadgeView(count: 0))
        guard let button = statusItem.button else { return }
        button.subviews.forEach { $0.removeFromSuperview() }
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = button.bounds
        hostingView.autoresizingMask = [.width, .height]
        button.addSubview(hostingView)
    }

    func update(count: Int) {
        hostingView.rootView = MenuBarBadgeView(count: count)
        statusItem.length = hostingView.fittingSize.width
        if let button = statusItem.button {
            hostingView.frame = button.bounds
        }
    }
}

struct MenuBarBadgeView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.25)
                )
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
            }
        }
        .foregroundColor(.primary)
        .padding(.horizontal, 2)
        .accessibilityLabel("GitWatch" + (count > 0 ? ", \(count) pull requests" : ""))
    }
}
