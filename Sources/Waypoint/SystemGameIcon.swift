import AppKit
import CryptoKit
import Darwin

/// NSWorkspace styles app icons, including legacy icns. These unindexed cache
/// bundles are only queried for artwork, never launched. macOS requires a
/// valid executable to avoid a prohibited badge; the fixed link to the system
/// `false` command supplies that metadata without adding executable code.
@MainActor
enum SystemGameIcon {
    private enum Failure: Error { case invalidArtwork, invalidCache, encoding }
    private static let template = "waypoint-system-game-icon-1\n"
    private static let supportExecutable = "/usr/bin/false"

    static func bundle(for artwork: Data, cache: URL? = nil) throws -> URL {
        guard !artwork.isEmpty, artwork.count <= 16 << 20 else { throw Failure.invalidArtwork }
        let fm = FileManager.default
        let root = cache ?? fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.waypoint.launcher")
            .appendingPathComponent("GameIcons.noindex", isDirectory: true)
        var identity = Data(template.utf8)
        identity.append(artwork)
        let id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let destination = root.appendingPathComponent(id + ".app", isDirectory: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.waypoint.game-icon." + id,
            "CFBundleName": "Game Icon", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon.icns", "CFBundleExecutable": "IconSupport",
            "LSMinimumSystemVersion": "14.0", "LSBackgroundOnly": true,
        ]
        if let type = try? fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType,
           type != .typeDirectory { throw Failure.invalidCache }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = open(root.appendingPathComponent("prepare.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw Failure.invalidCache }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0, fm.isExecutableFile(atPath: supportExecutable) else { throw Failure.invalidCache }
        defer { flock(lock, LOCK_UN) }
        if valid(destination, info: info) { return destination }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            where name.range(of: "^\\.[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil {
            try fm.removeItem(at: destination)
        }
        let staging = root.appendingPathComponent("." + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/Resources"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try iconData(artwork).write(to: staging.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: staging.appendingPathComponent("Contents/Info.plist"))
        try fm.createSymbolicLink(atPath: staging.appendingPathComponent("Contents/MacOS/IconSupport").path,
                                  withDestinationPath: supportExecutable)
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            // Another Waypoint instance may have finished the same artwork.
            guard valid(destination, info: info) else { throw error }
        }
        return destination
    }

    private static func valid(_ bundle: URL, info: [String: Any]) -> Bool {
        let fm = FileManager.default
        for path in ["", "Contents", "Contents/Resources", "Contents/MacOS"] {
            guard (try? fm.attributesOfItem(atPath: bundle.appendingPathComponent(path).path)[.type]
                    as? FileAttributeType) == .typeDirectory else { return false }
        }
        for path in ["Contents/Info.plist", "Contents/Resources/AppIcon.icns"] {
            guard let attributes = try? fm.attributesOfItem(atPath: bundle.appendingPathComponent(path).path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? UInt64, size > 0, size <= 8 << 20 else { return false }
        }
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary,
              stored.isEqual(to: info),
              (try? fm.destinationOfSymbolicLink(atPath: bundle.appendingPathComponent("Contents/MacOS/IconSupport").path))
                == supportExecutable else { return false }
        return true
    }

    private static func iconData(_ data: Data) throws -> Data {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw Failure.invalidArtwork }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let scale = min(824 / image.size.width, 824 / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (1024 - size.width) / 2, y: (1024 - size.height) / 2,
                             width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= 8 << 20
        else { throw Failure.encoding }
        // An ic10 element contains a 1024px PNG. ImageIO's icns writer does
        // not accept this single-representation family on every macOS version.
        var output = Data("icns".utf8)
        func appendLength(_ value: Int) {
            var word = UInt32(value).bigEndian
            withUnsafeBytes(of: &word) { output.append(contentsOf: $0) }
        }
        appendLength(png.count + 16)
        output.append(contentsOf: "ic10".utf8)
        appendLength(png.count + 8)
        output.append(png)
        return output
    }
}
