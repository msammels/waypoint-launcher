import Foundation
import Darwin

enum OverwatchSettings {
    /// Exclusive fullscreen can switch a Retina desktop to 1x while Wine's
    /// window retains its old point dimensions. Use borderless on first launch;
    /// later launches belong to the player's own saved display preferences.
    static func seed(in documents: URL, display: WindowsDisplay?) throws {
        let fm = FileManager.default
        let settings = documents.appendingPathComponent("Overwatch/Settings/Settings_v0.ini")
        guard !fm.fileExists(atPath: settings.path) else { return }
        for directory in [documents, documents.appendingPathComponent("Overwatch"), settings.deletingLastPathComponent()] {
            if let type = try? fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType,
               type != .typeDirectory { throw WindowsRuntime.Failure.invalidRuntime }
        }
        var text = """
        [Render.13]
        WindowMode = "1"
        WindowedFullscreen = "1"
        FullscreenWindow = "0"
        FullscreenWindowEnabled = "0"
        """ + "\n"
        if let display, display.width > 0, display.height > 0 {
            text += """
            FullScreenWidth = "\(display.width)"
            FullScreenHeight = "\(display.height)"
            WindowedWidth = "\(display.width)"
            WindowedHeight = "\(display.height)"
            WindowedPosX = "0"
            WindowedPosY = "0"
            """ + "\n"
        }
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = settings.deletingLastPathComponent().appendingPathComponent(".waypoint-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
        // Publish a complete file without replacing preferences created since
        // the existence check. Foundation cannot combine atomic and exclusive.
        if link(temporary.path, settings.path) != 0, errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
