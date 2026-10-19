import Foundation
import CryptoKit

/// The tiny title-aware helper is sealed into the native app, independently
/// of Wine. Its immutable copy remains usable if Sparkle replaces the app.
enum WindowsBridge {
    private struct Manifest: Decodable { let schema: Int; let sha256: String }

    static func install(from resources: URL, cache: URL = WindowsRuntime.support.appendingPathComponent("Bridges")) throws -> URL {
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
        guard manifest.schema == 2,
              manifest.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
        else { throw WindowsRuntime.Failure.invalidRuntime }
        let source = resources.appendingPathComponent("waypoint-launch-options.exe")
        let data = try Data(contentsOf: source)
        guard data.count <= 1_048_576,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256 else {
            throw WindowsRuntime.Failure.invalidRuntime
        }
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: cache.path), attrs[.type] as? FileAttributeType != .typeDirectory {
            throw WindowsRuntime.Failure.invalidRuntime
        }
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = cache.appendingPathComponent("bridge-\(manifest.sha256).exe")
        if (try? fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular,
           (try? WindowsRuntime.sha256(file)) == manifest.sha256 { return file }
        try data.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard try WindowsRuntime.sha256(file) == manifest.sha256 else { throw WindowsRuntime.Failure.invalidRuntime }
        return file
    }
}
