import AppKit

final class UpdaterWindowController: NSWindowController {
    private let statusLabel = NSTextField(labelWithString: "Installing update...")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "GitWatch Updater"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.standardWindowButton(.closeButton)?.isHidden = true

        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20)
        ])

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present(status: String) {
        statusLabel.stringValue = status
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
