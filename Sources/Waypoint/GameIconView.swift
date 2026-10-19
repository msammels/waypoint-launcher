import AppKit
import QuartzCore

/// Windows executables usually supply a bare logo. Give it the same visual
/// footprint as a Mac application icon, without changing the game's artwork.
@MainActor
final class GameIconView: NSView {
    private let artwork = NSImageView()
    private let plate = CAGradientLayer()

    var image: NSImage? {
        get { artwork.image }
        set { artwork.image = newValue }
    }

    var usesWindowsTile = false {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        plate.isHidden = true
        plate.cornerCurve = .continuous
        plate.colors = [
            NSColor(srgbRed: 0.29, green: 0.31, blue: 0.34, alpha: 1).cgColor,
            NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1).cgColor,
        ]
        plate.startPoint = CGPoint(x: 0.5, y: 1)
        plate.endPoint = CGPoint(x: 0.5, y: 0)
        plate.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        plate.borderWidth = 0.5
        plate.shadowColor = NSColor.black.cgColor
        plate.shadowOpacity = 0.20
        plate.shadowRadius = 1
        plate.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(plate)
        artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.setAccessibilityElement(false)
        addSubview(artwork)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.isHidden = !usesWindowsTile
        plate.frame = bounds.insetBy(dx: 4, dy: 4)
        plate.cornerRadius = plate.bounds.width * 0.225
        plate.shadowPath = CGPath(roundedRect: plate.bounds, cornerWidth: plate.cornerRadius,
                                  cornerHeight: plate.cornerRadius, transform: nil)
        artwork.frame = usesWindowsTile ? bounds.insetBy(dx: 9, dy: 9) : bounds
        CATransaction.commit()
    }
}
