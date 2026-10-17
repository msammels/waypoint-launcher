import AppKit
import WaypointCore

/// An installed game's text and spoken languages; shows what changing them
/// downloads, then does it like an update.
@MainActor
final class LanguageSheet: NSViewController {
    private let game: Game
    private let model: AppModel
    private let picker: LanguagePicker
    /// What the pop-ups showed at first; only something else is a change.
    private let initial: GameLanguages
    private var hasChange = false
    private var sizeTask: Task<Void, Never>?

    private let sizeSpinner = NSProgressIndicator.spinner()
    private let sizeText = NSTextField.label(.body)
    private let changeButton = NSButton(title: "Change", target: nil, action: nil)

    init(game: Game, model: AppModel) {
        self.game = game
        self.model = model
        let product = InstallableProduct.forProduct(game.install.productCode)
        let spoken = product?.hasSpokenLanguage ?? false
        let current = game.install.languages
        initial = spoken ? current : GameLanguages(text: current.text)
        picker = LanguagePicker(codes: product?.languages ?? [], selected: initial, hasSpokenLanguage: spoken)
        super.init(nibName: nil, bundle: nil)
        picker.onChange = { [weak self] in self?.refreshSize() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField.label(.title2)
        title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
        title.stringValue = "\(game.displayName) Languages"
        sizeText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grid = NSGridView(views: picker.rows + [
            [NSTextField(labelWithString: "Download:"), NSStackView(views: [sizeSpinner, sizeText])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8

        var views: [NSView] = [title, grid]
        if model.availableUpdate(for: game) != nil {
            let note = NSTextField(wrappingLabelWithString: "The waiting update is installed too.")
            note.textColor = .secondaryLabelColor
            views.append(note)
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        changeButton.target = self
        changeButton.action = #selector(change)
        changeButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.setViews([cancel, changeButton], in: .trailing)
        views.append(buttons)

        let stack = NSStackView.column(views, spacing: 16)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 480),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = stack
        refreshSize()
        // An update or the game starting meanwhile disables Change.
        observeChanges { [weak self] in self?.renderChangeButton() }
    }

    private func renderChangeButton() {
        changeButton.isEnabled = hasChange && model.canUpdate(game)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sizeTask?.cancel()
    }

    /// Asks again whenever a language changes, dropping an answer that's no
    /// longer wanted. The current languages need nothing. A WoW plan is big,
    /// so quick changes wait for the last one.
    private func refreshSize() {
        sizeTask?.cancel()
        let languages = picker.languages
        hasChange = languages != nil && languages != initial
        renderChangeButton()
        guard hasChange, let languages else {
            show(size: .success(0))
            sizeText.stringValue = "Nothing to change"
            sizeText.textColor = .secondaryLabelColor
            return
        }
        show(size: nil)
        let (game, model) = (game, model)
        sizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let size: Result<UInt64, Error>
            do {
                size = .success(try await model.languageChangeSize(game, to: languages))
            } catch {
                size = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.show(size: size)
        }
    }

    private func show(size: Result<UInt64, Error>?) {
        sizeSpinner.isHidden = size != nil
        if size == nil { sizeSpinner.startAnimation(nil) } else { sizeSpinner.stopAnimation(nil) }
        switch size {
        case nil:
            sizeText.stringValue = ""
        case .success(let bytes):
            sizeText.stringValue = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            sizeText.textColor = .labelColor
            sizeText.toolTip = nil
        case .failure(let error):
            sizeText.stringValue = errorMessage(error)
            sizeText.textColor = .systemRed
            sizeText.toolTip = sizeText.stringValue
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func change() {
        guard let languages = picker.languages else { return }
        let (game, model) = (game, model)
        Task { await model.changeLanguages(game, to: languages) }
        dismiss(nil)
    }
}
