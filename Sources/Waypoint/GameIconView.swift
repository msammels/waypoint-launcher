import AppKit
/// Retain system representations so macOS can apply Clear and Tinted styles.
@MainActor
final class GameIconView: NSImageView {
    private var filePath: String?
    private var windowsArtwork: Data?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshIcon),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func showWindowsArtwork(_ data: Data) {
        windowsArtwork = data
        filePath = nil
        refreshIcon()
    }

    func showFileIcon(at path: String?) {
        windowsArtwork = nil
        filePath = path
        refreshIcon()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshIcon()
    }

    @objc private func refreshIcon() {
        if let windowsArtwork {
            if let bundle = try? SystemGameIcon.bundle(for: windowsArtwork) {
                image = NSWorkspace.shared.icon(forFile: bundle.path)
            } else {
                image = NSImage(data: windowsArtwork)
            }
        } else {
            image = filePath.map { NSWorkspace.shared.icon(forFile: $0) }
                ?? NSWorkspace.shared.icon(for: .applicationBundle)
        }
        needsDisplay = true
    }
}
