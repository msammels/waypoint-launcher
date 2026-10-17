import AppKit
import WaypointCore

/// Text and spoken language pop-ups, as Battle.net offers them, or one
/// Language pop-up for games without a separate spoken language. Spoken
/// follows text until it's picked on its own: most people want both the same.
@MainActor
final class LanguagePicker: NSObject {
    private let textPopup = NSPopUpButton()
    private let speechPopup = NSPopUpButton()
    private let hasSpokenLanguage: Bool
    /// Called after either changes.
    var onChange: () -> Void = {}
    private var speechFollowsText: Bool

    var languages: GameLanguages? {
        guard let text = textPopup.selectedItem?.representedObject as? String else { return nil }
        guard hasSpokenLanguage else { return GameLanguages(text: text) }
        guard let speech = speechPopup.selectedItem?.representedObject as? String else { return nil }
        return GameLanguages(text: text, speech: speech)
    }

    /// Form rows (label, pop-up) for a grid.
    var rows: [[NSView]] {
        guard hasSpokenLanguage else { return [[NSTextField(labelWithString: "Language:"), textPopup]] }
        return [[NSTextField(labelWithString: "Text language:"), textPopup],
                [NSTextField(labelWithString: "Spoken language:"), speechPopup]]
    }

    /// `codes`: the game's languages. The selected ones are listed even if
    /// they aren't among them (an install Battle.net made).
    init(codes: [String], selected: GameLanguages, hasSpokenLanguage: Bool) {
        self.hasSpokenLanguage = hasSpokenLanguage
        speechFollowsText = selected.text == selected.speech
        super.init()
        var all = codes
        for code in hasSpokenLanguage ? [selected.text, selected.speech] : [selected.text] where !all.contains(code) {
            all.append(code)
        }
        for popup in [textPopup, speechPopup] {
            for code in all {
                popup.addItem(withTitle: Self.name(of: code))
                popup.lastItem?.representedObject = code
            }
            popup.target = self
        }
        textPopup.action = #selector(textChanged)
        speechPopup.action = #selector(speechChanged)
        select(selected.text, in: textPopup)
        select(selected.speech, in: speechPopup)
    }

    @objc private func textChanged() {
        if speechFollowsText, let text = languages?.text { select(text, in: speechPopup) }
        onChange()
    }

    @objc private func speechChanged() {
        speechFollowsText = languages.map { $0.text == $0.speech } ?? true
        onChange()
    }

    private func select(_ code: String, in popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == code }) { popup.select(item) }
    }

    /// "English (United States)" for `enUS`.
    static func name(of code: String) -> String {
        Locale.current.localizedString(forIdentifier: "\(code.prefix(2))_\(code.suffix(2))") ?? code
    }
}
