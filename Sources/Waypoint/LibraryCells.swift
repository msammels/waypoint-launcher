import AppKit
import UniformTypeIdentifiers
import WaypointCore

/// What a game row shows, read from the model in one go: the library
/// re-renders when any of it changes (see `LibraryViewController.render`).
struct GameRowState {
    var game: Game
    var phase: AppModel.Phase
    var isRunning: Bool
    var update: UpdateCheck?
    var canPlay: Bool
    var canUpdate: Bool
}

extension GameRowState {
    @MainActor init(_ game: Game, model: AppModel) {
        self.init(game: game, phase: model.phase(of: game), isRunning: model.isRunning(game),
                  update: model.availableUpdate(for: game), canPlay: model.canPlay(game),
                  canUpdate: model.canUpdate(game))
    }
}

/// A game being installed, or whose install failed.
struct InstallableRowState {
    var product: InstallableProduct
    var phase: AppModel.Phase
}

/// An installed game: icon, name, one quiet line of status, and Play or
/// Update on the right. Right-click for the other ways to play.
@MainActor
final class GameCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("game")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let progress = NSProgressIndicator.bar()
    private let detail = NSTextField.label(.subheadline, color: .secondaryLabelColor, monospacedDigits: true)
    private let status = NSTextField.label(.body, color: .secondaryLabelColor)
    private let spinner = NSProgressIndicator.spinner()
    private let button = NSButton(title: "Play", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let edition = NSPopUpButton()
    private var iconPath: String?
    private var state: GameRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        button.target = self
        button.action = #selector(primaryAction)
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownload)
        cancelButton.toolTip = "Stop this download. Downloaded data is kept for next time."
        edition.addItems(withTitles: ["Windows (recommended)", "macOS"])
        edition.menu?.autoenablesItems = false
        edition.controlSize = .small
        edition.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        edition.target = self
        edition.action = #selector(changeEdition)
        layOutRow(in: self, icon: icon, text: [name, edition, progress, detail], trailing: [status, spinner, cancelButton, button])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: GameRowState, model: AppModel) {
        self.state = state
        self.model = model
        let game = state.game
        let app = game.appURL ?? (game.install.productCode == "hero" ? model.heroesEdition(.macOS)?.appURL : nil)
        if icon.image == nil || iconPath != app?.path {
            iconPath = app?.path
            icon.image = iconPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .applicationBundle)
        }
        name.stringValue = game.displayName
        edition.isHidden = game.install.productCode != "hero" || (!WindowsHeroes.isAvailable && model.heroesEdition(.windows) == nil)
        edition.item(at: 0)?.title = WindowsHeroes.isAvailable ? "Windows (recommended)" : "Windows"
        edition.item(at: 0)?.isEnabled = WindowsHeroes.isAvailable
        edition.selectItem(at: game.install.platform == .windows ? 0 : 1)
        edition.isEnabled = !state.isRunning && !model.isSigningIn && state.phase != .launching
        toolTip = game.install.version.map { "Version \($0)" }

        progress.isHidden = true
        detail.textColor = .secondaryLabelColor
        detail.toolTip = nil
        switch state.phase {
        case .preparingWindows(let update):
            if let update {
                progress.doubleValue = update.fraction
                progress.isHidden = false
                detail.stringValue = "Windows components: " + progressDescription(update, waiting: "Downloading…")
            } else {
                detail.stringValue = "Preparing Windows version…"
            }
        case .updating(let update):
            progress.doubleValue = update?.fraction ?? 0
            progress.isHidden = false
            detail.stringValue = progressDescription(update, waiting: "Checking files…")
        case .pausing(let update), .paused(let update):
            progress.doubleValue = update?.fraction ?? 0
            progress.isHidden = false
            let pausing = if case .pausing = state.phase { true } else { false }
            detail.stringValue = downloadStatus(update, label: pausing ? "Pausing…" : "Paused")
        case .failed(let message):
            detail.stringValue = message
            detail.toolTip = message
            detail.textColor = .systemRed
        default:
            if state.update != nil, !state.isRunning {
                detail.stringValue = GameUpdate.canUpdate(game.install) ? "Update available" : "Update available in Battle.net"
                detail.textColor = .systemOrange
            } else {
                detail.stringValue = Self.summary(of: game)
            }
        }

        status.isHidden = true
        spinner.isHidden = true
        spinner.stopAnimation(nil)
        button.isHidden = true
        cancelButton.isHidden = !model.canCancelDownload(uid: game.id)
        let hasDownloadControls: Bool = switch state.phase {
        case .updating, .pausing, .paused: true
        default: false
        }
        if state.isRunning, !hasDownloadControls {
            show(status: "Running")
        } else if !game.isSupported, !hasDownloadControls {
            show(status: !game.isInstalled ? "Not installed" : (game.install.platform == .windows ? "Windows support unavailable" : (game.runsNatively ? "Unsupported" : "Needs Rosetta")))
        } else {
            switch state.phase {
            case .signingIn:
                showSpinner("Signing in…")
            case .preparingWindows:
                showSpinner("Preparing Windows version…")
            case .launching:
                showSpinner("Starting…")
            case .updating:
                button.title = "Pause"
                button.isEnabled = model.canPauseDownload(uid: game.id)
                button.isHidden = false
            case .pausing:
                button.title = "Pausing…"
                button.isEnabled = false
                button.isHidden = false
            case .paused:
                button.title = "Resume"
                button.isEnabled = model.canResumeDownload(uid: game.id)
                button.isHidden = false
            case .idle, .failed:
                let updates = state.update != nil && GameUpdate.canUpdate(game.install)
                let retry = model.canResumeDownload(uid: game.id)
                button.title = retry ? "Resume" : (updates ? "Update" : "Play")
                button.isEnabled = retry || (updates ? state.canUpdate : state.canPlay)
                button.isHidden = false
            }
        }
    }

    @objc private func changeEdition() {
        guard let model, let state, state.game.install.productCode == "hero" else { return }
        let platform: InstallPlatform = edition.indexOfSelectedItem == 0 ? .windows : .macOS
        guard platform == .macOS || WindowsHeroes.isAvailable else { return }
        if model.heroesEdition(platform)?.isInstalled == true {
            model.selectHeroesEdition(platform)
        } else if let product = InstallableProduct.forProduct("hero") {
            edition.selectItem(at: state.game.install.platform == .windows ? 0 : 1)
            window?.contentViewController?.presentAsSheet(InstallSheet(product: product, model: model, platform: platform))
        }
    }

    private func show(status text: String) {
        status.stringValue = text
        status.isHidden = false
    }

    private func showSpinner(_ help: String) {
        spinner.toolTip = help
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    @objc private func primaryAction() {
        guard let state, let model else { return }
        let game = state.game
        if model.canPauseDownload(uid: game.id) {
            model.pauseDownload(uid: game.id)
        } else if model.canResumeDownload(uid: game.id) {
            Task { await model.resumeDownload(uid: game.id) }
        } else if case .pausing = state.phase {
            return
        } else if case .paused = state.phase {
            return
        } else if state.update != nil, GameUpdate.canUpdate(game.install) {
            Task { await model.update(game) }
        } else {
            Task { await model.play(game) }
        }
    }

    @objc private func cancelDownload() {
        guard let state, let model else { return }
        model.cancelDownload(uid: state.game.id)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let state, let model, state.game.isSupported, !state.isRunning else { return nil }
        switch state.phase {
        case .idle, .failed: break
        default: return nil
        }
        let game = state.game
        let menu = NSMenu()
        if model.availableUpdate(for: game) != nil {
            menu.addItem(ActionItem("Play Without Updating") { Task { await model.play(game) } })
        }
        let others = model.accounts.filter { $0.id != model.activeAccount?.id }
        if !others.isEmpty {
            let playAs = NSMenuItem(title: "Play As", action: nil, keyEquivalent: "")
            playAs.submenu = NSMenu()
            for account in others {
                let item = ActionItem(account.displayName) { Task { await model.play(game, as: account.id) } }
                item.image = .account(account)
                playAs.submenu?.addItem(item)
            }
            menu.addItem(playAs)
        }
        menu.addItem(ActionItem("Sign In Again and Play") { Task { await model.play(game, forceSignIn: true) } })
        if GameUpdate.canUpdate(game.install) {
            menu.addItem(.separator())
            menu.addItem(ActionItem("Change Language…") { [weak self] in
                self?.window?.contentViewController?.presentAsSheet(LanguageSheet(game: game, model: model))
            })
            menu.addItem(ActionItem("Verify Files") { Task { await model.update(game, verify: true) } })
        }
        return menu
    }

    /// "36.6.3 · EU", plus "Intel" for games that need Rosetta. The full
    /// version is in the row's tooltip.
    private static func summary(of game: Game) -> String {
        var parts: [String] = []
        if let version = game.install.version {
            parts.append(version.split(separator: ".").prefix(3).joined(separator: "."))
        }
        if let region = game.install.region { parts.append(region.uppercased()) }
        if game.install.platform == .windows {
            parts.append("Windows")
            if WindowsTitle.forInstall(game.install)?.isQualified == false { parts.append("Preview") }
        }
        else if game.appURL != nil, !game.runsNatively { parts.append("Intel") }
        return parts.joined(separator: " · ")
    }
}

/// A game being installed (progress), or whose install was interrupted (Resume).
@MainActor
final class InstallableCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("installable")

    private let icon = NSImageView()
    private let name = NSTextField.label(.headline)
    private let progress = NSProgressIndicator.bar()
    private let detail = NSTextField.label(.subheadline, color: .secondaryLabelColor, monospacedDigits: true)
    private let button = NSButton(title: "Try Again…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var state: InstallableRowState?
    private var model: AppModel?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        icon.image = NSWorkspace.shared.icon(for: .applicationBundle)
        button.target = self
        button.action = #selector(install)
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownload)
        cancelButton.toolTip = "Stop this download. Downloaded data is kept for next time."
        layOutRow(in: self, icon: icon, text: [name, progress, detail], trailing: [cancelButton, button])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ state: InstallableRowState, model: AppModel) {
        self.state = state
        self.model = model
        name.stringValue = state.product.displayName
        cancelButton.isHidden = !model.canCancelDownload(uid: model.installKey(for: state.product))
        detail.toolTip = nil
        detail.textColor = .secondaryLabelColor
        progress.isHidden = false
        button.isHidden = false
        switch state.phase {
        case .failed(let message):
            progress.isHidden = true
            detail.stringValue = message
            detail.toolTip = message
            detail.textColor = .systemRed
            button.title = model.canResumeDownload(uid: model.installKey(for: state.product)) ? "Resume" : "Try Again…"
            button.isEnabled = true
        case .pausing(let update), .paused(let update):
            let pausing = if case .pausing = state.phase { true } else { false }
            progress.doubleValue = update?.fraction ?? 0
            detail.stringValue = downloadStatus(update, label: pausing ? "Pausing…" : "Paused")
            button.title = pausing ? "Pausing…" : "Resume"
            button.isEnabled = !pausing && model.canResumeDownload(uid: model.installKey(for: state.product))
        case .updating(let update):
            progress.doubleValue = update?.fraction ?? 0
            detail.stringValue = progressDescription(update, waiting: "Preparing…")
            button.title = "Pause"
            button.isEnabled = model.canPauseDownload(uid: model.installKey(for: state.product))
        default:
            button.isHidden = true
        }
    }

    @objc private func install() {
        guard let state, let model else { return }
        if model.canPauseDownload(uid: model.installKey(for: state.product)) {
            model.pauseDownload(uid: model.installKey(for: state.product))
            return
        }
        if model.canResumeDownload(uid: model.installKey(for: state.product)) {
            Task { await model.resumeDownload(uid: model.installKey(for: state.product)) }
            return
        }
        guard case .failed = state.phase else { return }
        window?.contentViewController?.presentAsSheet(InstallSheet(product: state.product, model: model))
    }

    @objc private func cancelDownload() {
        guard let state, let model else { return }
        model.cancelDownload(uid: model.installKey(for: state.product))
    }
}

/// A library row: a 40-point icon, a column of text that takes the free
/// width, and whatever of `trailing` is showing on the right.
@MainActor
private func layOutRow(in cell: NSView, icon: NSImageView, text views: [NSView], trailing: [NSView]) {
    icon.imageScaling = .scaleProportionallyUpOrDown
    let text = NSStackView.column(views, spacing: 3)
    text.setContentHuggingPriority(.init(1), for: .horizontal)
    let row = NSStackView(views: [icon, text] + trailing)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.distribution = .fill
    row.spacing = 10
    row.detachesHiddenViews = true
    row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    row.translatesAutoresizingMaskIntoConstraints = false
    cell.addSubview(row)
    let barWidth = views.compactMap { $0 as? NSProgressIndicator }.map { bar in
        let width = bar.widthAnchor.constraint(equalToConstant: 200)
        width.priority = .defaultHigh
        return [width, bar.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor)]
    }
    NSLayoutConstraint.activate(barWidth.flatMap { $0 } + [
        row.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        row.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        row.topAnchor.constraint(equalTo: cell.topAnchor),
        row.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        icon.widthAnchor.constraint(equalToConstant: 40),
        icon.heightAnchor.constraint(equalToConstant: 40),
    ])
}

/// "42% · 1.2 GB of 3 GB", or `waiting` before the first progress report.
private func progressDescription(_ progress: UpdateProgress?, waiting: String) -> String {
    guard let progress else { return waiting }
    let done = ByteCountFormatter.string(fromByteCount: Int64(progress.completedBytes), countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: Int64(progress.totalBytes), countStyle: .file)
    return "\(Int(progress.fraction * 100))% · \(done) of \(total)"
}

private func downloadStatus(_ progress: UpdateProgress?, label: String) -> String {
    guard let progress else { return label }
    return "\(label) · \(progressDescription(progress, waiting: label))"
}
