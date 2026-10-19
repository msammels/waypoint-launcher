import Foundation
import CryptoKit

/// An optional graphics component. HotS and Overwatch continue to use the
/// existing DXMT runtime; Diablo downloads the pinned, unmodified Apple stack.
public enum WindowsGraphics {
    enum Failure: Error, LocalizedError {
        case changedDistribution
        var errorDescription: String? { "The graphics download no longer matches this version of Waypoint. Update Waypoint before trying again." }
    }
    public static var resources: URL? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("WindowsGraphics"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else { return nil }
        return root
    }

    public static func licenseData(from resources: URL? = resources) throws -> Data {
        guard let resources else { throw WindowsRuntime.Failure.unavailable }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let data = try Data(contentsOf: resources.appendingPathComponent("License.rtf"))
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.files["License.rtf"] else {
            throw WindowsRuntime.Failure.invalidRuntime
        }
        return data
    }

    struct Manifest: Decodable, Sendable {
        let schema: Int
        let version: String
        let url: URL
        let bytes: Int64
        let sha256: String
        let archivePrefix: String
        let files: [String: String]
        let symlinks: [String: String]

        func validate() throws {
            guard schema == 1,
                  url.absoluteString == "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.15.tar.xz",
                  bytes == 87_477_092,
                  sha256 == "34273bcce885ce5a7fd6937af9ea344bb9961de7d55d6193f7413142e835c8c3",
                  archivePrefix == "Template-1.0.15.app/Contents/Frameworks/renderer/d3dmetal",
                  ["external/libd3dshared.dylib", "external/D3DMetal.framework/Versions/A/D3DMetal", "License.rtf"].allSatisfy({ files[$0] != nil }),
                  ["dxgi", "d3d11", "d3d12", "atidxx64"].allSatisfy({
                      files["wine/x86_64-windows/\($0).dll"] != nil &&
                      symlinks["wine/x86_64-unix/\($0).so"] == "../../external/libd3dshared.dylib"
                  }),
                  Set(files.keys).isDisjoint(with: symlinks.keys),
                  files.values.allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil })
            else { throw WindowsRuntime.Failure.invalidRuntime }
            for name in Array(files.keys) + Array(symlinks.keys) {
                guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else {
                    throw WindowsRuntime.Failure.invalidRuntime
                }
            }
        }
    }

    static func prepare(from resources: URL? = resources, cache: URL? = nil,
                        session: URLSession = .shared,
                        progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws -> URL {
        guard let resources else { throw WindowsRuntime.Failure.unavailable }
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: resources.appendingPathComponent("manifest.json")))
        try manifest.validate()
        let fm = FileManager.default
        let parent = cache ?? WindowsRuntime.support.appendingPathComponent("Graphics", isDirectory: true)
        if let type = try? fm.attributesOfItem(atPath: parent.path)[.type] as? FileAttributeType,
           type != .typeDirectory { throw WindowsRuntime.Failure.invalidRuntime }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lease = try PrefixLease(file: parent.appendingPathComponent("prepare.lock"))
        defer { lease.release() }
        for item in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            if item.lastPathComponent.range(of: "^\\.(graphics|retired)-[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil {
                try? fm.removeItem(at: item)
            }
        }
        let destination = parent.appendingPathComponent("d3dmetal-" + manifest.sha256)
        if (try? verify(manifest, at: destination)) != nil { return destination }
        try Task.checkCancellation()
        progress(UpdateProgress(completedBytes: 0, totalBytes: UInt64(manifest.bytes), completedFiles: 0, totalFiles: 1))
        let archive = try await NetworkRetry().run { _ in
            let file: URL, response: URLResponse
            do {
                (file, response) = try await DownloadTransfer(limiter: .shared, maximumBytes: manifest.bytes) { done, _ in
                    progress(UpdateProgress(completedBytes: UInt64(max(0, min(manifest.bytes, done))),
                        totalBytes: UInt64(manifest.bytes), completedFiles: 0, totalFiles: 1))
                }.download(session: session, request: URLRequest(url: manifest.url))
            } catch {
                let ns = error as NSError
                if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorDataLengthExceedsMaximum {
                    throw Failure.changedDistribution
                }
                throw error
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? fm.removeItem(at: file)
                throw HTTPFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, url: manifest.url)
            }
            return file
        }
        defer { try? fm.removeItem(at: archive) }
        let observedBytes = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let observedHash = try WindowsRuntime.sha256(archive)
        guard observedBytes == Int(manifest.bytes), observedHash == manifest.sha256 else {
            Log.error(.launch, "graphics_package_mismatch", nil, ["bytes": observedBytes, "sha256": observedHash, "expected_sha256": manifest.sha256])
            throw Failure.changedDistribution
        }
        try Task.checkCancellation()
        let staging = parent.appendingPathComponent(".graphics-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xJf", archive.path, "-C", staging.path, manifest.archivePrefix], directory: staging,
            environment: ["PATH": "/usr/bin:/bin"], timeout: 120)
        let root = staging.appendingPathComponent(manifest.archivePrefix)
        try verify(manifest, at: root)
        // Hash pinning authenticates the complete archive, while Apple's own
        // signature independently authenticates the intact framework.
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--deep", "--strict", "-R", "=anchor apple", root.appendingPathComponent("external/D3DMetal.framework").path],
            directory: staging, environment: ["PATH": "/usr/bin:/bin"], timeout: 30)
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--verify", "--strict", "-R", "=anchor apple", root.appendingPathComponent("external/libd3dshared.dylib").path],
            directory: staging, environment: ["PATH": "/usr/bin:/bin"], timeout: 30)
        try Task.checkCancellation()
        let retired = parent.appendingPathComponent(".retired-" + UUID().uuidString)
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil { try fm.moveItem(at: destination, to: retired) }
        do { try fm.moveItem(at: root, to: destination) }
        catch {
            if fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: destination) }
            throw error
        }
        try? fm.removeItem(at: retired)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var url = destination; try url.setResourceValues(excluded)
        progress(UpdateProgress(completedBytes: UInt64(manifest.bytes), totalBytes: UInt64(manifest.bytes), completedFiles: 1, totalFiles: 1))
        return destination
    }

    static func verify(_ manifest: Manifest, at root: URL) throws {
        try verifyFiles(manifest.files, symlinks: manifest.symlinks, at: root)
    }

    private static func verifyFiles(_ files: [String: String], symlinks: [String: String], at root: URL) throws {
        let fm = FileManager.default
        guard (try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType) == .typeDirectory,
              let entries = fm.enumerator(atPath: root.path) else { throw WindowsRuntime.Failure.invalidRuntime }
        let base = root.resolvingSymlinksInPath().path + "/"
        let allowed = Set(files.keys).union(symlinks.keys)
        for case let name as String in entries {
            let p = root.appendingPathComponent(name)
            let type = try fm.attributesOfItem(atPath: p.path)[.type] as? FileAttributeType
            guard p.resolvingSymlinksInPath().path.hasPrefix(base),
                  type == .typeDirectory || allowed.contains(name) else { throw WindowsRuntime.Failure.invalidRuntime }
        }
        for (name, hash) in files {
            let p = root.appendingPathComponent(name)
            guard p.resolvingSymlinksInPath().path.hasPrefix(base),
                  (try fm.attributesOfItem(atPath: p.path)[.type] as? FileAttributeType) == .typeRegular,
                  try WindowsRuntime.sha256(p) == hash else { throw WindowsRuntime.Failure.invalidRuntime }
        }
        for (name, target) in symlinks {
            let p = root.appendingPathComponent(name)
            guard p.resolvingSymlinksInPath().path.hasPrefix(base),
                  try fm.destinationOfSymbolicLink(atPath: p.path) == target else { throw WindowsRuntime.Failure.invalidRuntime }
        }
    }

    /// Wine prefers its own Unix DLLs over WINEDLLPATH. Give the Metal backend
    /// a complete, immutable engine directory rather than editing shared DXMT
    /// files or relying on an environment override that silently selects vkd3d.
    static func wineOverlay(baseRuntime: URL, graphics: URL, resources: URL, cacheRoot: URL) throws -> URL {
        struct WineManifest: Decodable { let files: [String: String]; let symlinks: [String: String]? }
        let wineData = try Data(contentsOf: baseRuntime.appendingPathComponent("runtime.json"))
        let graphicsData = try Data(contentsOf: resources.appendingPathComponent("manifest.json"))
        let source = try JSONDecoder().decode(WineManifest.self, from: wineData)
        let apple = try JSONDecoder().decode(Manifest.self, from: graphicsData)
        try apple.validate()
        var identity = Data("waypoint-metal-wine-overlay-1\n".utf8)
        identity.append(wineData); identity.append(graphicsData)
        let id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let destination = cacheRoot.appendingPathComponent("d3dmetal-" + id)
        var files: [String: String] = [:], links: [String: String] = [:]
        for (name, hash) in source.files where name.hasPrefix("wine/") { files[String(name.dropFirst(5))] = hash }
        for (name, target) in source.symlinks ?? [:] where name.hasPrefix("wine/") { links[String(name.dropFirst(5))] = target }
        func path(_ name: String) -> String? {
            if name.hasPrefix("wine/") { return "lib/" + name }
            if name.hasPrefix("external/") { return "lib/" + name }
            return nil
        }
        for (name, hash) in apple.files {
            guard let target = path(name) else { continue }
            files[target] = hash; links.removeValue(forKey: target)
        }
        for (name, target) in apple.symlinks {
            guard let name = path(name) else { continue }
            links[name] = target; files.removeValue(forKey: name)
        }
        let fm = FileManager.default
        let engine = destination.appendingPathComponent("wine")
        if (try? fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType) == .typeDirectory,
           fm.isExecutableFile(atPath: engine.appendingPathComponent("bin/wine").path),
           fm.isExecutableFile(atPath: engine.appendingPathComponent("bin/wineserver").path),
           (try? verifyFiles(files, symlinks: links, at: engine)) != nil {
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var installed = destination; try installed.setResourceValues(excluded)
            return engine
        }
        let staging = cacheRoot.appendingPathComponent(".metal-wine-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        let stagedWine = staging.appendingPathComponent("wine")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.copyItem(at: baseRuntime.appendingPathComponent("wine"), to: stagedWine)
        for (name, _) in apple.files {
            guard let nameInWine = path(name) else { continue }
            let target = stagedWine.appendingPathComponent(nameInWine)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
            try fm.copyItem(at: graphics.appendingPathComponent(name), to: target)
        }
        for (name, link) in apple.symlinks {
            guard let name = path(name) else { continue }
            let target = stagedWine.appendingPathComponent(name)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
        }
        try verifyFiles(files, symlinks: links, at: stagedWine)
        let retired = cacheRoot.appendingPathComponent(".retired-" + UUID().uuidString)
        if (try? fm.attributesOfItem(atPath: destination.path)) != nil { try fm.moveItem(at: destination, to: retired) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            if fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: destination) }
            throw error
        }
        try? fm.removeItem(at: retired)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var installed = destination; try installed.setResourceValues(excluded)
        return engine
    }

    /// Called under the global Windows lease after the current engine is
    /// prepared. Never remove another process's loader or follow a cache link.
    static func pruneEngines(in cache: URL, keeping engine: URL) {
        let fm = FileManager.default
        let current = engine.deletingLastPathComponent().lastPathComponent
        let active = RunningProcesses.executables().map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        for item in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            guard item.lastPathComponent != current,
                  item.lastPathComponent.range(of: "^(d3dmetal-[a-f0-9]{64}|\\.metal-wine-[A-Fa-f0-9-]{36})$", options: .regularExpression) != nil,
                  !active.contains(where: { $0.hasPrefix(item.resolvingSymlinksInPath().path + "/") }) else { continue }
            try? fm.removeItem(at: item)
        }
    }

    /// Metal games use only the complete overlay after preparation. The
    /// caller holds the global lease and has excluded every owned live game.
    static func pruneComponents(in cache: URL, keeping component: URL) {
        let fm = FileManager.default
        guard let lease = try? PrefixLease(file: cache.appendingPathComponent("prepare.lock")) else { return }
        defer { lease.release() }
        for item in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            guard item.lastPathComponent != component.lastPathComponent,
                  item.lastPathComponent.range(of: "^d3dmetal-[a-f0-9]{64}$", options: .regularExpression) != nil else { continue }
            try? fm.removeItem(at: item)
        }
    }
}
