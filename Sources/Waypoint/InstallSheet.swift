import AppKit
import WaypointCore

/// Where, which languages, which region; shows the real download size.
@MainActor
final class InstallSheet: NSViewController {
    private let product: InstallableProduct
    private let model: AppModel
    private var parentFolder = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private var sizeTask: Task<Void, Never>?

    private let location = NSTextField.label(.body, color: .secondaryLabelColor)
    private let languagePicker: LanguagePicker
    private let regionPopup = NSPopUpButton()
    private let sizeSpinner = NSProgressIndicator.spinner()
    private let sizeText = NSTextField.label(.body)
    private let installButton = NSButton(title: "Install", target: nil, action: nil)

    private var folder: URL { parentFolder.appendingPathComponent(product.folderName, isDirectory: true) }
    private var languages: GameLanguages? { languagePicker.languages }
    private var region: Region { Region.allCases[max(regionPopup.indexOfSelectedItem, 0)] }

    init(product: InstallableProduct, model: AppModel) {
        self.product = product
        self.model = model
        languagePicker = LanguagePicker(codes: product.languages, selected: GameLanguages(text: product.defaultLanguage()),
                                        hasSpokenLanguage: product.hasSpokenLanguage)
        super.init(nibName: nil, bundle: nil)
        languagePicker.onChange = { [weak self] in self?.refreshSize() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let title = NSTextField.label(.title2)
        title.font = .boldSystemFont(ofSize: title.font?.pointSize ?? 17)
        title.stringValue = "Install \(product.displayName)"

        location.lineBreakMode = .byTruncatingMiddle
        let change = NSButton(title: "Change…", target: self, action: #selector(chooseParent))
        let locationRow = NSStackView(views: [location, change])
        regionPopup.addItems(withTitles: Region.allCases.map(\.displayName))
        regionPopup.selectItem(at: Region.allCases.firstIndex(of: model.regionOverride ?? Region.default()) ?? 0)
        regionPopup.target = self
        regionPopup.action = #selector(refreshSize)
        sizeText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let grid = NSGridView(views: [[Self.formLabel("Location:"), locationRow]] + languagePicker.rows + [
            [Self.formLabel("Region:"), regionPopup],
            [Self.formLabel("Download:"), NSStackView(views: [sizeSpinner, sizeText])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.columnSpacing = 8

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        installButton.target = self
        installButton.action = #selector(install)
        installButton.keyEquivalent = "\r"
        installButton.isEnabled = languages != nil
        let buttons = NSStackView()
        buttons.setViews([cancel, installButton], in: .trailing)

        let stack = NSStackView.column([title, grid, buttons], spacing: 16)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 480),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = stack
        showLocation()
        refreshSize()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sizeTask?.cancel()
    }

    private func showLocation() {
        location.stringValue = folder.path
        location.toolTip = folder.path
    }

    /// The download size depends on languages and region; asks again when
    /// any changes, dropping an answer that's no longer wanted.
    @objc private func refreshSize() {
        sizeTask?.cancel()
        let (product, model, folder, region) = (product, model, folder, region)
        guard let languages else { return }
        show(size: nil)
        sizeTask = Task { [weak self] in
            // A WoW plan is big: quick changes wait for the last one.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let size: Result<(download: UInt64, stored: UInt64), Error>
            do {
                size = .success(try await model.installSize(product, folder: folder, region: region, languages: languages))
            } catch {
                size = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.show(size: size)
        }
    }

    private func show(size: Result<(download: UInt64, stored: UInt64), Error>?) {
        sizeSpinner.isHidden = size != nil
        if size == nil { sizeSpinner.startAnimation(nil) } else { sizeSpinner.stopAnimation(nil) }
        switch size {
        case nil:
            sizeText.stringValue = ""
        case .success(let bytes):
            let download = ByteCountFormatter.string(fromByteCount: Int64(bytes.download), countStyle: .file)
            sizeText.stringValue = bytes.stored == 0 ? download
                : "\(download) left (\(ByteCountFormatter.string(fromByteCount: Int64(bytes.stored), countStyle: .file)) already downloaded)"
            sizeText.textColor = .labelColor
            sizeText.toolTip = nil
        case .failure(let error):
            sizeText.stringValue = errorMessage(error)
            sizeText.textColor = .systemRed
            sizeText.toolTip = sizeText.stringValue
        }
    }

    @objc private func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "\(product.displayName) will be installed in a \"\(product.folderName)\" folder here."
        panel.directoryURL = parentFolder
        if panel.runModal() == .OK, let url = panel.url {
            parentFolder = url
            showLocation()
            refreshSize() // another folder may hold a partial install, or not
        }
    }

    @objc private func cancel() {
        dismiss(nil)
    }

    @objc private func install() {
        let (product, model, folder, region) = (product, model, folder, region)
        guard let languages else { return }
        Task { await model.install(product, folder: folder, region: region, languages: languages) }
        dismiss(nil)
    }

    private static func formLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }
}
