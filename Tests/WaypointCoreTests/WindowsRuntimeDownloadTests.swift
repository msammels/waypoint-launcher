import Foundation
import Testing
import CryptoKit
@testable import WaypointCore

private struct RuntimeFixture {
    let directory: URL
    let resources: URL
    let cache: URL
    let archive: URL
    var descriptor: WindowsRuntimeDistribution

    init() async throws {
        let fm = FileManager.default
        directory = fm.temporaryDirectory.appendingPathComponent("runtime-download-" + UUID().uuidString)
        resources = directory.appendingPathComponent("descriptor")
        cache = directory.appendingPathComponent("cache")
        archive = directory.appendingPathComponent("fixture.zip")
        let app = directory.appendingPathComponent("Waypoint Windows Runtime.app")
        let root = app.appendingPathComponent("Contents/Resources/Windows")
        try fm.createDirectory(at: root.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let contents = ["wine/bin/wine": Data("fixture wine".utf8), "waypoint-launch-options.exe": Data("fixture helper".utf8)]
        for (name, data) in contents { try data.write(to: root.appendingPathComponent(name)) }
        let manifest: [String: Any] = ["recipe": 1,
            "wineSourceSHA256": "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872",
            "dxmtSHA256": "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
            "files": contents.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)
        try manifestData.write(to: root.appendingPathComponent("runtime.json"))
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", app.path, archive.path], directory: directory, environment: [:])
        descriptor = WindowsRuntimeDistribution(schema: 1,
            url: URL(string: "https://storage.yandexcloud.net/macos-releases/waypoint/windows/\(try WindowsHeroes.sha256(archive)).zip")!,
            bytes: Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!),
            sha256: try WindowsHeroes.sha256(archive),
            manifestSHA256: SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined())
        try saveDescriptor()
    }

    func saveDescriptor() throws {
        try JSONEncoder().encode(descriptor).write(to: resources.appendingPathComponent("distribution.json"))
    }

    func copiedArchive() throws -> URL {
        let copy = directory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.copyItem(at: archive, to: copy)
        return copy
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor FetchCounter {
    var calls = 0
    func count() { calls += 1 }
}

@Test func runtimeTransferStopsWhenTheResponseExceedsItsPinnedSize() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let transfer = DownloadTransfer(limiter: DownloadBandwidthLimiter(), maximumBytes: 1024)
    do {
        let (file, _) = try await transfer.download(session: .shared,
            request: URLRequest(url: server.url.appendingPathComponent("normal/component.zip")))
        try? FileManager.default.removeItem(at: file)
        Issue.record("Oversized component response was accepted")
    } catch {
        #expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
    }
}

@Test func onDemandRuntimeInstallsThenWorksOfflineAndRepairsDamage() async throws {
    let fixture = try await RuntimeFixture()
    defer { fixture.remove() }
    let count = FetchCounter()
    let fetch: WindowsRuntimeDownload.Fetch = { _, _ in await count.count(); return try fixture.copiedArchive() }
    let first = try await WindowsRuntimeDownload.prepare(from: fixture.resources, cacheRoot: fixture.cache, fetch: fetch)
    let second = try await WindowsRuntimeDownload.prepare(from: fixture.resources, cacheRoot: fixture.cache, fetch: { _, _ in
        Issue.record("A valid cache must work without a network request"); throw URLError(.notConnectedToInternet)
    })
    #expect(first == second)
    let abandoned = fixture.cache.appendingPathComponent(".download-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
    try Data("damaged cache".utf8).write(to: first.appendingPathComponent("wine/bin/wine"))
    let repaired = try await WindowsRuntimeDownload.prepare(from: fixture.resources, cacheRoot: fixture.cache, fetch: fetch)
    #expect(repaired == first)
    #expect(try String(contentsOf: repaired.appendingPathComponent("wine/bin/wine"), encoding: .utf8) == "fixture wine")
    #expect(await count.calls == 2)
    #expect(!FileManager.default.fileExists(atPath: abandoned.path))
}

@Test func onDemandRejectsTamperedArchiveBeforeExtraction() async throws {
    let fixture = try await RuntimeFixture()
    defer { fixture.remove() }
    var corrupted = try Data(contentsOf: fixture.archive)
    corrupted[0] ^= 0x80 // Keep the pinned size; exercise hash verification.
    try corrupted.write(to: fixture.archive)
    await #expect(throws: WindowsHeroes.Failure.invalidRuntime) {
        try await WindowsRuntimeDownload.prepare(from: fixture.resources, cacheRoot: fixture.cache,
            fetch: { _, _ in try fixture.copiedArchive() })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
}

@Test func onDemandRejectsTheWrongManifestAndRemovesStaging() async throws {
    var fixture = try await RuntimeFixture()
    defer { fixture.remove() }
    fixture.descriptor.manifestSHA256 = String(repeating: "a", count: 64)
    try fixture.saveDescriptor()
    let captured = fixture
    await #expect(throws: WindowsHeroes.Failure.invalidRuntime) {
        try await WindowsRuntimeDownload.prepare(from: captured.resources, cacheRoot: captured.cache,
            fetch: { _, _ in try captured.copiedArchive() })
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path).isEmpty)
}

@Test func onDemandRejectsUnsafeDistributionURLsAndSizes() throws {
    var d = WindowsRuntimeDistribution(schema: 1,
        url: URL(string: "https://storage.yandexcloud.net/macos-releases/waypoint/windows/\(String(repeating: "a", count: 64)).zip")!,
        bytes: 100, sha256: String(repeating: "a", count: 64), manifestSHA256: String(repeating: "b", count: 64))
    try d.validate()
    for value in ["http://storage.yandexcloud.net/macos-releases/waypoint/windows/\(d.sha256).zip",
                  "https://example.com/macos-releases/waypoint/windows/\(d.sha256).zip",
                  "https://storage.yandexcloud.net/another-app/\(d.sha256).zip",
                  "https://storage.yandexcloud.net/macos-releases/waypoint/windows/\(d.sha256).zip?latest=1"] {
        d.url = URL(string: value)!
        #expect(throws: WindowsHeroes.Failure.invalidRuntime) { try d.validate() }
    }
    d.url = URL(string: "https://storage.yandexcloud.net/macos-releases/waypoint/windows/\(d.sha256).zip")!
    d.bytes = 536_870_913
    #expect(throws: WindowsHeroes.Failure.invalidRuntime) { try d.validate() }
}

@Test func onDemandCancellationDoesNotInstallTheDownloadedFile() async throws {
    let fixture = try await RuntimeFixture()
    defer { fixture.remove() }
    let task = Task {
        try await WindowsRuntimeDownload.prepare(from: fixture.resources, cacheRoot: fixture.cache, fetch: { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return try fixture.copiedArchive()
        })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
}
