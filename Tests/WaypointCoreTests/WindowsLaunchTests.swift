import Foundation
import Testing
import CryptoKit
@testable import WaypointCore

@Test func windowsTicketProtocolKeepsIssuingAndPlayRegionsIndependent() throws {
    let token = try #require(LoginToken("US-0123456789abcdef0123456789abcdef-1"))
    let frame = try WindowsLaunchOptions.frame(token: token, region: .eu, locale: "enUS")
    #expect(String(data: frame, encoding: .utf8) == "WAYPOINT-HERO-1\n\(token.value)\nEU\nenUS\n")
    #expect(throws: (any Error).self) {
        try WindowsLaunchOptions.frame(token: token, region: .eu, locale: "enUS\nUS")
    }
    var mutated = token
    mutated.value += "\nclear\n"
    #expect(throws: (any Error).self) {
        try WindowsLaunchOptions.frame(token: mutated, region: .eu, locale: nil)
    }
}

@Test func childCommandReceivesPipeEOFAndPropagatesExitFailure() async throws {
    let env = ["PATH": "/usr/bin:/bin"]
    try await ChildCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "read -r first; read -r second; test \"$first\" = dummy && test \"$second\" = end && ! read -r extra"],
        directory: URL(fileURLWithPath: "/tmp"), environment: env, input: Data("dummy\nend\n".utf8))
    await #expect(throws: (any Error).self) {
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
            directory: URL(fileURLWithPath: "/tmp"), environment: env)
    }
}

@Test func childCommandHasBoundedLifetimeAndSupportsCancellation() async throws {
    let executable = URL(fileURLWithPath: "/bin/sleep")
    let dir = URL(fileURLWithPath: "/tmp")
    await #expect(throws: ChildCommand.Failure.timedOut) {
        try await ChildCommand.run(executable: executable, arguments: ["30"], directory: dir,
                                   environment: [:], timeout: 0.05)
    }
    let task = Task { try await ChildCommand.run(executable: executable, arguments: ["30"], directory: dir,
                                               environment: [:]) }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func helperSuccessRequiresExplicitStatusAndAcknowledgement() async throws {
    let sh = URL(fileURLWithPath: "/bin/sh"), dir = URL(fileURLWithPath: "/tmp")
    let ack = Data("ok\n".utf8)
    try await ChildCommand.run(executable: sh, arguments: ["-c", "printf 'ok\\n'; exit 87"],
                               directory: dir, environment: [:], successStatus: 87, acknowledgement: ack)
    await #expect(throws: (any Error).self) {
        try await ChildCommand.run(executable: sh, arguments: ["-c", "printf 'ok\\n'; exit 0"],
                                   directory: dir, environment: [:], successStatus: 87, acknowledgement: ack)
    }
    await #expect(throws: ChildCommand.Failure.invalidAcknowledgement) {
        try await ChildCommand.run(executable: sh, arguments: ["-c", "exit 87"], directory: dir,
                                   environment: [:], successStatus: 87, acknowledgement: ack)
    }
}

@Test func cancellingHandoffStillRunsTokenCleanup() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-cancel-handoff-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let helper = dir.appendingPathComponent("helper.sh")
    try Data("read -r mode\nif [ \"$mode\" = clear ]; then touch cleared; printf 'ok\\n'; exit 87; fi\nexit 1\n".utf8).write(to: helper)
    let token = try #require(LoginToken("US-0123456789abcdef0123456789abcdef-1"))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await WindowsLaunchOptions.write(token: token, region: .eu, locale: "enUS",
            wine: URL(fileURLWithPath: "/bin/sh"), helper: helper, prefix: dir,
            environment: ["PATH": "/usr/bin:/bin"])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("cleared").path))
}

@Test func criticalHandoffCompletesAndAcknowledgesAfterCancellation() async throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-critical-handoff-\(UUID().uuidString)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let task = Task {
        try await ChildCommand.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "touch started; sleep 0.2; printf 'ok\\n'; exit 87"], directory: dir,
            environment: ["PATH": "/usr/bin:/bin"], successStatus: 87,
            acknowledgement: Data("ok\n".utf8), completeOnCancellation: true)
    }
    for _ in 0..<100 where !fm.fileExists(atPath: dir.appendingPathComponent("started").path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fm.fileExists(atPath: dir.appendingPathComponent("started").path))
    task.cancel()
    try await task.value
}

@Test func runtimeCacheIsVerifiedAndOutlivesItsAppResources() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-runtime-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let resources = dir.appendingPathComponent("resources"), cache = dir.appendingPathComponent("cache")
    try fm.createDirectory(at: resources.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
    let files = ["wine/bin/wine": Data("dummy Wine fixture".utf8), "waypoint-launch-options.exe": Data("dummy helper fixture".utf8)]
    for (name, data) in files { try data.write(to: resources.appendingPathComponent(name)) }
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.appendingPathComponent("wine/bin/wine").path)
    try fm.createSymbolicLink(atPath: resources.appendingPathComponent("wine/bin/wine64").path, withDestinationPath: "wine")
    let hashes = files.mapValues { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    let manifest: [String: Any] = ["recipe": 1,
        "wineSourceSHA256": "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872",
        "dxmtSHA256": "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d", "files": hashes,
        "symlinks": ["wine/bin/wine64": "wine"], "fileModes": ["wine/bin/wine": 0o755]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: resources.appendingPathComponent("runtime.json"))
    try Data("corrupted".utf8).write(to: resources.appendingPathComponent("wine/bin/wine"))
    #expect(throws: (any Error).self) { try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache) }
    #expect((try? fm.contentsOfDirectory(atPath: cache.path))?.isEmpty != false)
    try files["wine/bin/wine"]!.write(to: resources.appendingPathComponent("wine/bin/wine"))
    let installed = try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache)
    #expect(try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache) == installed)
    try Data("damaged cached component".utf8).write(to: installed.appendingPathComponent("wine/bin/wine"))
    #expect(try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache) == installed)
    #expect(try Data(contentsOf: installed.appendingPathComponent("wine/bin/wine")) == files["wine/bin/wine"])
    try fm.removeItem(at: installed.appendingPathComponent("runtime.json"))
    #expect(try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache) == installed)
    try fm.removeItem(at: installed.appendingPathComponent("wine/bin/wine64"))
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: installed.appendingPathComponent("wine/bin/wine").path)
    #expect(try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache) == installed)
    #expect(fm.isExecutableFile(atPath: installed.appendingPathComponent("wine/bin/wine").path))
    #expect(try fm.destinationOfSymbolicLink(atPath: installed.appendingPathComponent("wine/bin/wine64").path) == "wine")
    let unexpected = installed.appendingPathComponent("wine/bin/unexpected.dylib")
    try Data("unexpected component".utf8).write(to: unexpected)
    #expect(try WindowsHeroes.installRuntime(from: resources, cacheRoot: cache) == installed)
    #expect(!fm.fileExists(atPath: unexpected.path))
    try fm.removeItem(at: resources)
    #expect(try Data(contentsOf: installed.appendingPathComponent("wine/bin/wine")) == files["wine/bin/wine"])
}

@Test func windowsHeroesPlanUsesSwitcherBridgeWithoutAMacBundle() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("waypoint-win-plan-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try fm.createDirectory(at: dir.appendingPathComponent("Support64"), withIntermediateDirectories: true)
    try Data("MZ fixture".utf8).write(to: dir.appendingPathComponent("Support64/HeroesSwitcher_x64.exe"))
    let game = GameCatalog.game(for: ProductInstall(uid: "heroes", productCode: "hero", installPath: dir.path,
        region: "eu", textLanguage: "enUS", tagString: "Windows EU enUS text", platform: .windows))
    #expect(game.appURL == nil)
    #expect(game.isInstalled)
    if !Rosetta.isInstalled {
        #expect(throws: (any Error).self) { try GameLauncher.plan(for: game, windowsResources: dir.appendingPathComponent("resources")) }
        return
    }
    let plan = try GameLauncher.plan(for: game, windowsResources: dir.appendingPathComponent("resources"))
    #expect(plan.isWindows)
    #expect(plan.codename == "Hero")
    #expect(plan.region == .eu)
    #expect(plan.locale == "enUS")
    #expect(plan.executable.lastPathComponent == "wine")
    #expect(plan.arguments.count == 1)
    #expect(plan.arguments[0].hasSuffix("waypoint-launch-options.exe"))
}
