import Foundation
import Testing
import CryptoKit
@testable import WaypointCore

private struct GraphicsFixture {
    let root: URL
    let resources: URL
    let graphics: URL
    let manifest: WindowsGraphics.Manifest

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resources = root.appendingPathComponent("resources")
        graphics = root.appendingPathComponent("graphics")
        let contents = [
            "License.rtf": "fixture terms",
            "external/libd3dshared.dylib": "fixture Apple Unix DLL",
            "external/D3DMetal.framework/Versions/A/D3DMetal": "fixture framework",
            "wine/x86_64-windows/d3d12.dll": "fixture Apple PE",
            "wine/x86_64-windows/d3d11.dll": "fixture D3D11 PE",
            "wine/x86_64-windows/dxgi.dll": "fixture DXGI PE",
            "wine/x86_64-windows/atidxx64.dll": "fixture AMD PE",
        ]
        var hashes: [String: String] = [:]
        for (path, text) in contents {
            let bytes = Data(text.utf8), file = graphics.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file)
            hashes[path] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        let links = Dictionary(uniqueKeysWithValues: ["dxgi", "d3d11", "d3d12", "atidxx64"].map {
            ("wine/x86_64-unix/\($0).so", "../../external/libd3dshared.dylib")
        })
        for (path, target) in links {
            let file = graphics.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: target)
        }
        // Real distribution pins, tiny synthetic contents: tests never download
        // or execute third-party code and can exercise an offline verified cache.
        let data = try JSONSerialization.data(withJSONObject: [
            "schema": 1, "version": "test", "bytes": 87_477_092,
            "url": "https://github.com/Sikarugir-App/Wrapper/releases/download/v1.0/Template-1.0.15.tar.xz",
            "sha256": "34273bcce885ce5a7fd6937af9ea344bb9961de7d55d6193f7413142e835c8c3",
            "archivePrefix": "Template-1.0.15.app/Contents/Frameworks/renderer/d3dmetal",
            "files": hashes, "symlinks": links,
        ])
        manifest = try JSONDecoder().decode(WindowsGraphics.Manifest.self, from: data)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try data.write(to: resources.appendingPathComponent("manifest.json"))
        try Data(contentsOf: graphics.appendingPathComponent("License.rtf")).write(to: resources.appendingPathComponent("License.rtf"))
        try manifest.validate()
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func graphicsCacheRejectsExtraCodeAndChangedFiles() throws {
    let fixture = try GraphicsFixture()
    defer { fixture.remove() }
    try WindowsGraphics.verify(fixture.manifest, at: fixture.graphics)
    let extra = fixture.graphics.appendingPathComponent("wine/injected.dll")
    try Data("unexpected".utf8).write(to: extra)
    #expect(throws: (any Error).self) { try WindowsGraphics.verify(fixture.manifest, at: fixture.graphics) }
    try FileManager.default.removeItem(at: extra)
    try Data("corrupt".utf8).write(to: fixture.graphics.appendingPathComponent("wine/x86_64-windows/d3d12.dll"))
    #expect(throws: (any Error).self) { try WindowsGraphics.verify(fixture.manifest, at: fixture.graphics) }
}

@Test func graphicsCacheRejectsRetargetedAndReplacedSymlinks() throws {
    let fixture = try GraphicsFixture(), fm = FileManager.default
    defer { fixture.remove() }
    let outside = fixture.root.appendingPathComponent("outside.dylib")
    try Data("outside".utf8).write(to: outside)
    let link = fixture.graphics.appendingPathComponent("wine/x86_64-unix/d3d12.so")
    try fm.removeItem(at: link)
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try WindowsGraphics.verify(fixture.manifest, at: fixture.graphics) }
    try fm.removeItem(at: link)
    try fm.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.manifest.symlinks["wine/x86_64-unix/d3d12.so"]!)
    let file = fixture.graphics.appendingPathComponent("wine/x86_64-windows/d3d12.dll")
    try fm.moveItem(at: file, to: fixture.root.appendingPathComponent("original.dll"))
    try fm.createSymbolicLink(at: file, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try WindowsGraphics.verify(fixture.manifest, at: fixture.graphics) }
    #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
}

@Test func graphicsLicenseIsBoundToTheDownloadedComponent() throws {
    let fixture = try GraphicsFixture()
    defer { fixture.remove() }
    #expect(try WindowsGraphics.licenseData(from: fixture.resources) == Data("fixture terms".utf8))
    try Data("different terms".utf8).write(to: fixture.resources.appendingPathComponent("License.rtf"))
    #expect(throws: (any Error).self) { try WindowsGraphics.licenseData(from: fixture.resources) }
}

@Test func graphicsVerifiedCacheCanBeUsedOffline() async throws {
    let fixture = try GraphicsFixture(), fm = FileManager.default
    defer { fixture.remove() }
    let cache = fixture.root.appendingPathComponent("cache")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    let expected = cache.appendingPathComponent("d3dmetal-" + fixture.manifest.sha256)
    try fm.copyItem(at: fixture.graphics, to: expected)
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1,
                                       "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    let prepared = try await WindowsGraphics.prepare(from: fixture.resources, cache: cache, session: session)
    #expect(prepared.path == expected.path)
}

@Test func metalEngineRepairsItselfWithoutChangingTheSharedDXMTEngine() throws {
    let fixture = try GraphicsFixture(), fm = FileManager.default
    defer { fixture.remove() }
    let runtime = fixture.root.appendingPathComponent("base"), cache = fixture.root.appendingPathComponent("engines")
    let baseFiles = ["wine/bin/wine": "engine", "wine/bin/wineserver": "server",
                     "wine/lib/wine/x86_64-windows/d3d12.dll": "original vkd3d",
                     "wine/lib/wine/x86_64-unix/d3d12.so": "original Unix DLL"]
    var hashes: [String: String] = [:]
    for (path, text) in baseFiles {
        let bytes = Data(text.utf8), file = runtime.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        hashes[path] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    try JSONSerialization.data(withJSONObject: ["files": hashes]).write(to: runtime.appendingPathComponent("runtime.json"))
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    let engine = try WindowsGraphics.wineOverlay(baseRuntime: runtime, graphics: fixture.graphics, resources: fixture.resources, cacheRoot: cache)
    let dll = engine.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")
    #expect(try Data(contentsOf: dll) == Data("fixture Apple PE".utf8))
    #expect(try fm.destinationOfSymbolicLink(atPath: engine.appendingPathComponent("lib/wine/x86_64-unix/d3d12.so").path)
        == "../../external/libd3dshared.dylib")
    #expect(try String(contentsOf: runtime.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d12.dll"), encoding: .utf8) == "original vkd3d")
    try Data("corrupt overlay".utf8).write(to: dll)
    let repaired = try WindowsGraphics.wineOverlay(baseRuntime: runtime, graphics: fixture.graphics, resources: fixture.resources, cacheRoot: cache)
    #expect(repaired.path == engine.path)
    #expect(try Data(contentsOf: dll) == Data("fixture Apple PE".utf8))
    #expect(try String(contentsOf: runtime.appendingPathComponent("wine/lib/wine/x86_64-unix/d3d12.so"), encoding: .utf8) == "original Unix DLL")
    let destination = engine.deletingLastPathComponent(), outside = fixture.root.appendingPathComponent("outside-engine")
    try fm.moveItem(at: destination, to: outside)
    try fm.createSymbolicLink(at: destination, withDestinationURL: outside)
    let contained = try WindowsGraphics.wineOverlay(baseRuntime: runtime, graphics: fixture.graphics, resources: fixture.resources, cacheRoot: cache)
    #expect(contained.resolvingSymlinksInPath().path.hasPrefix(cache.resolvingSymlinksInPath().path + "/"))
    #expect(try Data(contentsOf: outside.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d12.dll")) == Data("fixture Apple PE".utf8))
    try fm.removeItem(at: destination)
    try fm.createSymbolicLink(at: destination, withDestinationURL: fixture.root.appendingPathComponent("missing-engine"))
    let danglingRepair = try WindowsGraphics.wineOverlay(baseRuntime: runtime, graphics: fixture.graphics, resources: fixture.resources, cacheRoot: cache)
    #expect(try Data(contentsOf: danglingRepair.appendingPathComponent("lib/wine/x86_64-windows/d3d12.dll")) == Data("fixture Apple PE".utf8))
}

@Test func checkedInGraphicsDescriptorAndLicenseAreValid() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #expect(try !WindowsGraphics.licenseData(from: repo.appendingPathComponent("Resources/WindowsGraphics")).isEmpty)
}

#if WAYPOINT_WINDOWS_EXPERIMENTAL
@Test(.enabled(if: WindowsTitle.diabloIV.isHostSupported))
func failedGraphicsPreparationNeverBootsAnEmptyPrefixWithTheBaseEngine() async throws {
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let resources = root.appendingPathComponent("bundle"), bridge = root.appendingPathComponent("bridge")
    let support = root.appendingPathComponent("support"), game = root.appendingPathComponent("game")
    let script = Data("#!/bin/sh\nprintf called >> '\(root.path)/wine-called'\nexit 1\n".utf8)
    let contents = ["wine/bin/wine": script, "wine/bin/wineserver": script, "waypoint-launch-options.exe": Data("MZfixture".utf8)]
    var hashes: [String: String] = [:], modes: [String: Int] = [:]
    for (name, bytes) in contents {
        let file = resources.appendingPathComponent(name)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        hashes[name] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        modes[name] = 0o700
    }
    try JSONSerialization.data(withJSONObject: ["recipe": 1,
        "wineSourceSHA256": "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872",
        "dxmtSHA256": "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
        "files": hashes, "fileModes": modes]).write(to: resources.appendingPathComponent("runtime.json"))
    try fm.createDirectory(at: bridge, withIntermediateDirectories: true)
    try contents["waypoint-launch-options.exe"]!.write(to: bridge.appendingPathComponent("waypoint-launch-options.exe"))
    try JSONSerialization.data(withJSONObject: ["schema": 2, "sha256": hashes["waypoint-launch-options.exe"]!])
        .write(to: bridge.appendingPathComponent("manifest.json"))
    // The bridge has been installed, but the graphics descriptor is missing.
    let target = WindowsLaunchTarget(install: ProductInstall(uid: "fenris", productCode: "fenris", installPath: game.path,
        tagString: "Windows enUS text", platform: .windows), resources: resources, display: nil,
        bridgeResources: bridge, graphicsResources: root.appendingPathComponent("missing-graphics"))
    let session = try WindowsGameSession(target: target, supportRoot: support)
    await #expect(throws: (any Error).self) { try await session.prepare() }
    await session.preparationFailed()
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("wine-called").path))
    #expect(try fm.contentsOfDirectory(atPath: support.appendingPathComponent("Windows/fenris/prefix-v1").path).isEmpty)
}
#endif
