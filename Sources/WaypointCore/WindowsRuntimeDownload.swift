import Foundation
import CryptoKit

/// The descriptor is sealed into Waypoint's signed bundle. There is no mutable
/// server-side "latest" manifest: an app update selects a new component hash.
struct WindowsRuntimeDistribution: Codable, Sendable {
    var schema: Int
    var url: URL
    var bytes: Int64
    var sha256: String
    var manifestSHA256: String

    func validate() throws {
        guard schema == 1, url.scheme == "https", url.host == "storage.yandexcloud.net",
              url.user == nil, url.password == nil, url.port == nil,
              url.path.hasPrefix("/macos-releases/waypoint/windows/"),
              url.path.hasSuffix(".zip"), url.query == nil, url.fragment == nil,
              (1...536_870_912).contains(bytes),
              [sha256, manifestSHA256].allSatisfy({ $0.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil })
        else { throw WindowsHeroes.Failure.invalidRuntime }
    }
}

enum WindowsRuntimeDownload {
    typealias Fetch = @Sendable (WindowsRuntimeDistribution, @escaping @Sendable (UpdateProgress) -> Void) async throws -> URL

    static func prepare(from resources: URL, cacheRoot: URL? = nil,
                        session: URLSession = .shared,
                        fetch: Fetch? = nil,
                        progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: resources.appendingPathComponent("runtime.json").path) {
            return try await Task.detached { try WindowsHeroes.installRuntime(from: resources, cacheRoot: cacheRoot) }.value
        }
        let distribution = try JSONDecoder().decode(WindowsRuntimeDistribution.self,
            from: Data(contentsOf: resources.appendingPathComponent("distribution.json")))
        try distribution.validate()
        let cache = cacheRoot ?? WindowsHeroes.support.appendingPathComponent("Runtimes", isDirectory: true)
        let cached = cache.appendingPathComponent("heroes-" + distribution.manifestSHA256)
        if let result = try? await Task.detached(operation: {
            try checkManifest(in: cached, distribution: distribution)
            return try WindowsHeroes.installRuntime(from: cached, cacheRoot: cache)
        }).value {
            try Task.checkCancellation()
            return result
        }
        try Task.checkCancellation()
        progress(UpdateProgress(completedBytes: 0, totalBytes: UInt64(distribution.bytes), completedFiles: 0, totalFiles: 1))
        let archive = try await (fetch ?? { distribution, progress in
            try await fetchArchive(distribution, session: session, progress: progress)
        })(distribution, progress)
        defer { try? fm.removeItem(at: archive) }
        // No archive member is extracted or executed before authentication.
        guard try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(distribution.bytes),
              try WindowsHeroes.sha256(archive) == distribution.sha256 else { throw WindowsHeroes.Failure.invalidRuntime }
        try Task.checkCancellation()
        try fm.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = cache.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, staging.path], directory: staging,
            environment: ["PATH": "/usr/bin:/bin"], timeout: 120)
        let root = staging.appendingPathComponent("Waypoint Windows Runtime.app/Contents/Resources/Windows", isDirectory: true)
        try checkManifest(in: root, distribution: distribution)
        try Task.checkCancellation()
        let installed = try await Task.detached { try WindowsHeroes.installRuntime(from: root, cacheRoot: cache) }.value
        try Task.checkCancellation()
        progress(UpdateProgress(completedBytes: UInt64(distribution.bytes), totalBytes: UInt64(distribution.bytes), completedFiles: 1, totalFiles: 1))
        return installed
    }

    private static func fetchArchive(_ distribution: WindowsRuntimeDistribution, session: URLSession,
                                     progress: @escaping @Sendable (UpdateProgress) -> Void) async throws -> URL {
        try await NetworkRetry().run { _ in
            var request = URLRequest(url: distribution.url)
            request.timeoutInterval = 120
            let (file, response) = try await DownloadTransfer(limiter: .shared, maximumBytes: distribution.bytes) { done, _ in
                progress(UpdateProgress(completedBytes: UInt64(max(0, min(distribution.bytes, done))),
                    totalBytes: UInt64(distribution.bytes), completedFiles: 0, totalFiles: 1))
            }.download(session: session, request: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: file)
                throw HTTPFailure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, url: distribution.url)
            }
            return file
        }
    }

    private static func checkManifest(in root: URL, distribution: WindowsRuntimeDistribution) throws {
        let file = root.appendingPathComponent("runtime.json")
        guard try WindowsHeroes.sha256(file) == distribution.manifestSHA256 else { throw WindowsHeroes.Failure.invalidRuntime }
    }
}
