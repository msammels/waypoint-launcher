import Foundation
import Testing
@testable import WaypointCore

@Test func windowsConfigurationSelectsWindowsBinariesAndTags() throws {
    let json = Data(#"{"all":{"config":{"data_dir":"HeroesData/"}},"platform":{"mac":{"config":{"tags":["OSX","code"],"tags_64bit":["x86_64"],"binaries":{"game":{"relative_path":"Support/HeroesSwitcher.app"}}}},"win":{"config":{"tags":["Windows","code"],"tags_64bit":["x86_64"],"binaries":{"game":{"relative_path_64":"Support64/HeroesSwitcher_x64.exe"}}}}}}"#.utf8)
    let win = try ProductConfig(json: json, platform: .windows)
    let mac = try ProductConfig(json: json)
    #expect(win.gameBinary == "Support64/HeroesSwitcher_x64.exe")
    #expect(win.tagString(region: .eu, language: "enUS") == "Windows code x86_64 EU? enUS speech?:Windows code x86_64 EU? enUS text?")
    #expect(mac.gameBinary == "Support/HeroesSwitcher.app")
    #expect(mac.extraTags.contains("arm64"))
    #expect(!win.extraTags.contains("arm64"))
    #expect(throws: (any Error).self) { try ProductConfig(json: Data(#"{"platform":{"mac":{"config":{}}}}"#.utf8), platform: .windows) }
}

@Test func stateKeepsNativeAndWindowsHotSIndependently() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = InstallStateStore(file: dir.appendingPathComponent("installs.json"))
    let mac = ProductInstall(uid: "heroes", productCode: "hero", installPath: "/Applications/Heroes of the Storm")
    let win = ProductInstall(uid: "heroes", productCode: "hero", installPath: "/private/wine/drive_c/HotS", platform: .windows)
    try store.record(uid: mac.uid, InstalledBuild(buildConfig: "mac-build", version: "1.0", install: mac))
    try store.record(install: win, InstalledBuild(buildConfig: "win-build", version: "2.0"))
    #expect(Set(store.load().keys) == ["heroes", "heroes@windows"])
    #expect(store.apply(to: mac).buildConfig == "mac-build")
    #expect(store.apply(to: win).buildConfig == "win-build")
    #expect(store.apply(to: win).platform == .windows)
    #expect(win.with(GameLanguages(text: "deDE"), tags: "Windows code EU? enUS text?").platform == .windows)
    let nativeFile = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String: Any])
    #expect(Set(nativeFile.keys) == ["heroes"], "Older versions must never see a Windows path")
    #expect(FileManager.default.fileExists(atPath: store.windowsFile.path))
    #expect(throws: (any Error).self) { try store.record(uid: win.key, InstalledBuild(buildConfig: "bad", version: "3")) }
    let installs = store.standaloneInstalls()
    #expect(installs.count == 2)
    #expect(installs.allSatisfy { $0.uid == "heroes" })
    #expect(Set(installs.map(\.platform)) == [.macOS, .windows])
    try Data("{}".utf8).write(to: store.file)
    #expect(store.load()[win.key]?.platform == .windows, "An older native writer must not erase Windows state")
    // Old JSON has no platform; preserve its native identity.
    let old = try JSONDecoder().decode(InstalledBuild.self, from: Data(#"{"buildConfig":"old","version":"1","productCode":"hero","installPath":"/Applications/HotS"}"#.utf8))
    #expect(old.install(uid: "heroes")?.platform == .macOS)
}

@Test func interruptedInstallKeepsItsPlatformBeforeBuildInfoExists() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let win = ProductInstall(uid: "heroes", productCode: "hero", installPath: dir.path, platform: .windows)
    let mac = ProductInstall(uid: "heroes", productCode: "hero", installPath: dir.path)
    try win.platform.claim(install: win)
    try win.platform.claim(install: win)
    #expect(throws: (any Error).self) { try mac.platform.claim(install: mac) }
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".build.info").path))
}

@Test func emptyProductStillChecksThePlatform() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let win = ProductInstall(uid: "heroes", productCode: "hero", installPath: dir.path, platform: .windows)
    try "Product!STRING:0|Tags!STRING:0\n|OSX code\n".write(to: dir.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try win.platform.validate(install: win) }
}

@Test func nativeBuildRepairToleratesIncompleteLegacyMetadata() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let install = ProductInstall(uid: "wow", productCode: "wow", installPath: dir.path)
    for content in ["", "Version!STRING:0\n1", "Tags!STRING:0|Version!STRING:0\n|1"] {
        try content.write(to: dir.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
        try install.platform.validate(install: install)
    }
}

@Test func refusesAnotherPlatformsBuildRecordBeforeWriting() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Tags!STRING:0|Version!STRING:0\nOSX code EU? enUS text?|1\n".write(to: dir.appendingPathComponent(".build.info"), atomically: true, encoding: .utf8)
    let windows = ProductInstall(uid: "heroes", productCode: "hero", installPath: dir.path, platform: .windows)
    #expect(throws: (any Error).self) { try windows.platform.validate(install: windows) }
    let mac = ProductInstall(uid: "heroes", productCode: "hero", installPath: dir.path)
    try mac.platform.validate(install: mac)
}
