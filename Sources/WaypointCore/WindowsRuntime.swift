import Foundation
import CryptoKit
import Darwin

public struct WindowsDisplay: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public init(width: Int, height: Int, framesPerSecond: Int) {
        self.width = width; self.height = height
        self.framesPerSecond = min(240, max(30, framesPerSecond))
    }
}

struct WindowsLaunchTarget: Equatable, Sendable {
    var install: ProductInstall
    var resources: URL
    var display: WindowsDisplay?
    var bridgeResources: URL? = nil
    var graphicsResources: URL? = nil
}

public enum WindowsRuntime {
    public static var resources: URL? {
        let fm = FileManager.default
        if let url = Bundle.main.sharedSupportURL?.appendingPathComponent("Windows"),
           fm.fileExists(atPath: url.appendingPathComponent("runtime.json").path) { return url }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("WindowsRuntime"),
           fm.fileExists(atPath: url.appendingPathComponent("distribution.json").path) { return url }
        return nil
    }

    public static var bridgeResources: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("WindowsBridge"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else { return nil }
        return url
    }

    static var isHostSupported: Bool {
        #if arch(arm64)
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
            && Rosetta.isInstalled
        #else
        false
        #endif
    }

    public static var isAvailable: Bool { isHostSupported && resources != nil }

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Waypoint", isDirectory: true)

    enum Failure: Error, LocalizedError, Equatable {
        case unavailable, unsupportedHost(WindowsTitle), busy, invalidRuntime, startup
        var errorDescription: String? {
            switch self {
            case .unavailable: "Windows game components are unavailable in this build of Waypoint."
            case .unsupportedHost(let title): "The Windows version of \(title.displayName) requires an Apple silicon Mac with macOS \(title.minimumOS.majorVersion).\(title.minimumOS.minorVersion) or later and Rosetta."
            case .busy: "A Windows game is already running or starting."
            case .invalidRuntime: "The Windows game components could not be verified. Try again to download a fresh copy."
            case .startup: "The Windows game closed before finishing startup."
            }
        }
    }

    private struct Manifest: Decodable {
        var recipe: Int
        var wineSourceSHA256: String
        var dxmtSHA256: String
        var files: [String: String]
        var symlinks: [String: String]?
        var fileModes: [String: Int]?
    }

    /// Copy a sealed, bundled runtime into an immutable version directory.
    /// A game can outlive Waypoint or a Sparkle update of the app bundle.
    static func installRuntime(from resources: URL, cacheRoot: URL? = nil) throws -> URL {
        let data = try Data(contentsOf: resources.appendingPathComponent("runtime.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.recipe == 1,
              manifest.wineSourceSHA256 == "ac99c8ca4b3848f3e81784135f023df266b61c2345726ea55a50b3e030dd6872",
              manifest.dxmtSHA256 == "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
              manifest.files["wine/bin/wine"] != nil,
              manifest.files["waypoint-launch-options.exe"] != nil else { throw Failure.invalidRuntime }
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let parent = cacheRoot ?? support.appendingPathComponent("Runtimes", isDirectory: true)
        let destination = parent.appendingPathComponent("heroes-\(id)", isDirectory: true)
        let fm = FileManager.default
        if (try? Data(contentsOf: destination.appendingPathComponent("runtime.json"))) == data,
           (try? verify(manifest, in: destination)) != nil {
            return destination
        }
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".heroes-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: resources, to: staging)
        try verify(manifest, in: staging)
        // A cleaner may have removed a cached component. Repair from the
        // sealed app atomically, preserving the old copy if the move fails.
        let retired = parent.appendingPathComponent(".retired-\(UUID().uuidString)")
        if fm.fileExists(atPath: destination.path) { try fm.moveItem(at: destination, to: retired) }
        do { try fm.moveItem(at: staging, to: destination) }
        catch {
            if fm.fileExists(atPath: retired.path) { try? fm.moveItem(at: retired, to: destination) }
            throw error
        }
        try? fm.removeItem(at: retired)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var url = destination; try url.setResourceValues(excluded)
        return destination
    }

    private static func verify(_ manifest: Manifest, in root: URL) throws {
        let fm = FileManager.default
        let allowed = Set(manifest.files.keys).union(manifest.symlinks?.keys.map { $0 } ?? []).union(["runtime.json"])
        // FileManager's URL enumerator canonicalizes /var to /private/var on
        // macOS. Relative-path enumeration preserves manifest names directly.
        guard let entries = fm.enumerator(atPath: root.path) else { throw Failure.invalidRuntime }
        for case let name as String in entries {
            let entry = root.appendingPathComponent(name)
            let type = try fm.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType
            if type != .typeDirectory {
                guard allowed.contains(name) else { throw Failure.invalidRuntime }
            }
        }
        func file(_ name: String) throws -> URL {
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw Failure.invalidRuntime }
            let file = root.appendingPathComponent(name)
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw Failure.invalidRuntime
            }
            return file
        }
        for (name, expected) in manifest.files {
            let file = try file(name)
            guard (try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw Failure.invalidRuntime
            }
            let hash = try sha256(file)
            guard hash == expected else { throw Failure.invalidRuntime }
        }
        for (name, expected) in manifest.symlinks ?? [:] {
            let file = try file(name)
            guard try fm.destinationOfSymbolicLink(atPath: file.path) == expected else { throw Failure.invalidRuntime }
        }
        for (name, expected) in manifest.fileModes ?? [:] {
            let file = try file(name)
            guard (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == expected else {
                throw Failure.invalidRuntime
            }
        }
    }

    /// Recover ticket cleanup when the game outlived the app that launched it.
    public static func cleanupAfterExit(install: ProductInstall) async {
        guard WindowsTitle.forInstall(install)?.isEnabled == true else { return }
        let target = WindowsLaunchTarget(install: install, resources: support, display: nil)
        guard let session = try? WindowsHeroesSession(target: target) else { return }
        await session.recoverExitCleanup()
    }

    static func sha256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Holds a prefix lease from preparation through game exit. The prefix is
/// Waypoint-owned; another launcher's credentials or bottle are never read.
public typealias WindowsHeroes = WindowsRuntime
public typealias WindowsHeroesSession = WindowsGameSession

public actor WindowsGameSession {
    private let target: WindowsLaunchTarget
    private let supportRoot: URL
    private let title: WindowsTitle
    private let globalLease: PrefixLease
    private var titleHelper: URL?
    private var graphics: URL?
    private var metalWineRoot: URL?
    private let lease: PrefixLease
    private let prefix: URL
    private var runtime: URL?
    private var launched = false
    private var cleanupTask: Task<Void, Never>?
    private var prefixValidated = false

    func matches(_ target: WindowsLaunchTarget) -> Bool { self.target == target }

    init(target: WindowsLaunchTarget, supportRoot: URL = WindowsRuntime.support) throws {
        guard let title = WindowsTitle.forInstall(target.install) else { throw LaunchError.unsupported(target.install.productCode) }
        self.target = target
        self.supportRoot = supportRoot
        self.title = title
        let windows = supportRoot.appendingPathComponent("Windows", isDirectory: true)
        if let type = try? FileManager.default.attributesOfItem(atPath: windows.path)[.type] as? FileAttributeType,
           type != .typeDirectory { throw WindowsRuntime.Failure.invalidRuntime }
        try FileManager.default.createDirectory(at: windows, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        globalLease = try PrefixLease(file: windows.appendingPathComponent("launch.lock"))
        let home = windows.appendingPathComponent(title.prefixFolder, isDirectory: true)
        if (try? FileManager.default.attributesOfItem(atPath: home.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw WindowsHeroes.Failure.invalidRuntime
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        lease = try PrefixLease(file: home.appendingPathComponent("launch.lock"))
        prefix = home.appendingPathComponent("prefix-v1", isDirectory: true)
    }

    func prepare(progress: @escaping @Sendable (UpdateProgress) -> Void = { _ in }) async throws {
        guard title.isEnabled else { throw LaunchError.unsupported(title.displayName) }
        guard title.isHostSupported else { throw WindowsRuntime.Failure.unsupportedHost(title) }
        let root = URL(fileURLWithPath: target.install.installPath, isDirectory: true)
        try target.install.platform.validate(install: target.install)
        // A game may have outlived a previous Waypoint process, including a
        // game installed in another folder. Do not remap its shared H: drive.
        guard WineProcesses.gameCore(in: root, title: title).isEmpty,
              WineProcesses.ownedGames(runtimeCache: supportRoot.appendingPathComponent("Runtimes")).isEmpty
        else { throw WindowsHeroes.Failure.busy }
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: prefix.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw WindowsHeroes.Failure.invalidRuntime
        }
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: prefix.path)
        prefixValidated = true
        var backup = URLResourceValues(); backup.isExcludedFromBackup = true
        var prefixURL = prefix; try prefixURL.setResourceValues(backup)
        let resources: URL
        if let custom = UserDefaults.standard.string(forKey: "windowsRuntimeOverride") {
            // An explicit local choice lets users run their own compatible
            // LGPL builds. Never weaken verification of downloaded components.
            guard custom.hasPrefix("/") else { throw WindowsHeroes.Failure.invalidRuntime }
            resources = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            resources = target.resources
        }
        let preparedRuntime = try await WindowsRuntimeDownload.prepare(from: resources, cacheRoot: supportRoot.appendingPathComponent("Runtimes"), progress: progress)
        let preparedHelper: URL?
        if title != .heroes {
            guard let bridge = target.bridgeResources ?? WindowsRuntime.bridgeResources else { throw WindowsRuntime.Failure.unavailable }
            preparedHelper = try WindowsBridge.install(from: bridge, cache: supportRoot.appendingPathComponent("Bridges"))
        } else { preparedHelper = nil }
        let preparedGraphics: URL?, preparedMetalWine: URL?
        if title.backend == .d3dMetal {
            guard let graphicsResources = target.graphicsResources ?? WindowsGraphics.resources else { throw WindowsRuntime.Failure.unavailable }
            let component = try await WindowsGraphics.prepare(from: graphicsResources,
                cache: supportRoot.appendingPathComponent("Graphics"), progress: progress)
            preparedGraphics = component
            preparedMetalWine = try WindowsGraphics.wineOverlay(baseRuntime: preparedRuntime, graphics: component, resources: graphicsResources,
                cacheRoot: supportRoot.appendingPathComponent("Runtimes"))
        } else { preparedGraphics = nil; preparedMetalWine = nil }
        // A cancelled component download must not let rollback initialize an
        // empty prefix with the base engine or bypass its display defaults.
        runtime = preparedRuntime; titleHelper = preparedHelper
        graphics = preparedGraphics; metalWineRoot = preparedMetalWine
        let ready = prefix.appendingPathComponent(".waypoint-ready-v1")
        let runtimeID = runtime!.lastPathComponent
        let previousRuntime = (try? String(contentsOf: ready, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let graphicsReady = prefix.appendingPathComponent(".waypoint-graphics-v1")
        let previousGraphics = try? String(contentsOf: graphicsReady, encoding: .utf8)
        let graphicsIdentity = metalWineRoot?.deletingLastPathComponent().lastPathComponent
        let needsSetup = previousRuntime != runtimeID || (graphicsIdentity != nil && previousGraphics != graphicsIdentity)
        if needsSetup {
            // Stop a previous engine with its own protocol before updating
            // this prefix. The process checks above exclude a live game.
            if let previousRuntime, previousRuntime.range(of: "^heroes-[a-f0-9]{64}$", options: .regularExpression) != nil {
                let server = runtime!.deletingLastPathComponent().appendingPathComponent(previousRuntime + "/wine/bin/wineserver")
                let usableServer = fm.isExecutableFile(atPath: server.path) ? server : wineRoot.appendingPathComponent("bin/wineserver")
                if fm.isExecutableFile(atPath: usableServer.path) {
                    // -k also returns 1 for a stale, unlocked server lock.
                    try? await ChildCommand.run(executable: usableServer, arguments: ["-k"], directory: prefix, environment: environment)
                    try await ChildCommand.run(executable: usableServer, arguments: ["-w"], directory: prefix, environment: environment, timeout: 15)
                }
            }
            let registry = prefix.appendingPathComponent("user.reg")
            if !fm.fileExists(atPath: registry.path) {
                try Data("WINE REGISTRY Version 2\n#arch=win64\n\n[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=\"Y\"\n\n[Control Panel\\\\Desktop]\n\"LogPixels\"=dword:00000060\n".utf8)
                    .write(to: registry, options: .atomic)
            }
            try await ChildCommand.run(executable: wine, arguments: ["wineboot", "-u"], directory: prefix,
                                       environment: environment, timeout: 120)
        }
        let helper = try helperURL()
        try await WindowsLaunchOptions.prepare(wine: wine, helper: helper, prefix: prefix, environment: environment, title: title)
        // HotS ships its Windows dependencies alongside the switcher. Keep
        // them in this private prefix rather than requiring a redistributable
        // installer or borrowing files from another launcher.
        let system = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        if let graphics {
            for name in ["dxgi", "d3d11", "d3d12", "atidxx64"] {
                let source = graphics.appendingPathComponent("wine/x86_64-windows/\(name).dll")
                let destination = system.appendingPathComponent("\(name).dll")
                let data = try Data(contentsOf: source)
                if (try? Data(contentsOf: destination)) != data { try data.write(to: destination, options: .atomic) }
            }
        }
        let support = root.appendingPathComponent(title.dependencyFolder, isDirectory: true)
        let dependencies = ["vcruntime140.dll", "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
                            "concrt140.dll", "vccorlib140.dll", "msvcr100.dll", "msvcp100.dll",
                            "ucrtbase.dll", "api-ms-win-crt-private-l1-1-0.dll", "d3dcompiler_47.dll", "d3dx11_42.dll"] + (title == .heroes ? [] : ["vcruntime140_1.dll"])
        for name in dependencies {
            let source = support.appendingPathComponent(name), destination = system.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let incoming = try Data(contentsOf: source, options: .mappedIfSafe)
            if (try? Data(contentsOf: destination, options: .mappedIfSafe)) == incoming { continue }
            let temporary = system.appendingPathComponent(".waypoint-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            try fm.copyItem(at: source, to: temporary)
            guard rename(temporary.path, destination.path) == 0 else { throw WindowsHeroes.Failure.invalidRuntime }
        }
        // Wine normally links these folders to the host. Replace links, never
        // their destinations, before HotS can write a native game's settings.
        let users = prefix.appendingPathComponent("drive_c/users", isDirectory: true)
        let profiles = try fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil).filter {
            (try? fm.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType) == .typeDirectory
        }
        for user in profiles {
            for name in ["Documents", "My Documents", "Desktop", "Downloads", "Pictures", "Music", "Videos"] {
                let folder = user.appendingPathComponent(name, isDirectory: true)
                if (try? fm.attributesOfItem(atPath: folder.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                    try fm.removeItem(at: folder)
                }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let sentinel = folder.appendingPathComponent(".waypoint-local")
                if !fm.fileExists(atPath: sentinel.path) { try Data().write(to: sentinel) }
            }
        }
        let drive = prefix.appendingPathComponent("dosdevices/h:")
        if let attributes = try? fm.attributesOfItem(atPath: drive.path) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { throw WindowsHeroes.Failure.invalidRuntime }
            try fm.removeItem(at: drive)
        }
        try fm.createSymbolicLink(at: drive, withDestinationURL: root)
        if needsSetup && title == .heroes {
            for user in profiles
            where user.lastPathComponent != "Public" {
                let variables = user.appendingPathComponent("Documents/Heroes of the Storm/Variables.txt")
                try fm.createDirectory(at: variables.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: variables.path) else { continue }
                var settings = "displaymode=1\nwindowstate=3\nvsync=false\nframeratecap=0\nframeratecapGlue=60\n"
                if let display = target.display, display.width > 0, display.height > 0 {
                    settings += "width=\(display.width)\nheight=\(display.height)\nwindowwidth=\(display.width)\nwindowheight=\(display.height)\n"
                }
                try Data(settings.utf8).write(to: variables, options: .atomic)
            }
        }
        try await clear()
        if let graphicsIdentity { try Data(graphicsIdentity.utf8).write(to: graphicsReady, options: .atomic) }
        try Data((runtimeID + "\n").utf8).write(to: ready, options: .atomic)
        let parent = runtime!.deletingLastPathComponent()
        if let metalWineRoot { WindowsGraphics.pruneEngines(in: parent, keeping: metalWineRoot) }
        if let graphics { WindowsGraphics.pruneComponents(in: supportRoot.appendingPathComponent("Graphics"), keeping: graphics) }
        let activePaths = RunningProcesses.executables().map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        for candidate in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? [] {
            guard candidate.lastPathComponent != runtimeID,
                  candidate.lastPathComponent.range(of: "^(heroes-[a-f0-9]{64}|\\.heroes-[A-Fa-f0-9-]{36}|\\.retired-[A-Fa-f0-9-]{36})$", options: .regularExpression) != nil,
                  !activePaths.contains(where: { $0.hasPrefix(candidate.resolvingSymlinksInPath().path + "/") }) else { continue }
            try? fm.removeItem(at: candidate)
        }
    }

    func launch(token: LoginToken, region: Region, locale: String?) async throws -> Int32 {
        guard runtime != nil, !launched else { throw WindowsHeroes.Failure.busy }
        let helper = try helperURL()
        launched = true
        let root = URL(fileURLWithPath: target.install.installPath, isDirectory: true)
        guard WineProcesses.gameAndLaunchers(in: root, title: title, runtime: wineRoot).isEmpty else { throw WindowsHeroes.Failure.busy }
        do {
            try await WindowsLaunchOptions.write(token: token, region: region, locale: locale, wine: wine,
                helper: helper, prefix: prefix, environment: environment, launch: true, title: title)
        } catch {
            // CreateProcessW may already have succeeded before a timeout.
            // Reconcile the owned process before clearing its login ticket.
            if let pid = WineProcesses.gameCore(in: root, title: title, runtime: wineRoot).first { return pid }
            if !WineProcesses.gameAndLaunchers(in: root, title: title, runtime: wineRoot).isEmpty,
               let pid = await findCore(seconds: 20) { return pid }
            if let pid = WineProcesses.gameAndLaunchers(in: root, title: title, runtime: wineRoot).first { return pid }
            await rollback()
            throw error
        }
        if let pid = await findCore(seconds: 60) { return pid }
        // A cold Switcher can still be verifying files. Observe it until it
        // exits, then follow any Core it created; do not kill a healthy start.
        if let pid = WineProcesses.gameAndLaunchers(in: root, title: title, runtime: wineRoot).first { return pid }
        await rollback()
        throw WindowsHeroes.Failure.startup
    }

    public func gameExited() async -> [Int32] {
        if let cleanupTask { await cleanupTask.value; return [] }
        guard runtime != nil else { lease.release(); globalLease.release(); return [] }
        let root = URL(fileURLWithPath: target.install.installPath, isDirectory: true)
        let survivors = WineProcesses.gameAndLaunchers(in: root, title: title, runtime: wineRoot)
        guard survivors.isEmpty else { return survivors }
        guard let helper = try? helperURL() else { lease.release(); globalLease.release(); return [] }
        let wine = wine, prefix = prefix, environment = environment, title = title
        let cleanup = Task.detached { try? await WindowsLaunchOptions.clear(wine: wine, helper: helper, prefix: prefix,
                                                                           environment: environment, title: title); return () }
        cleanupTask = cleanup
        await cleanup.value
        lease.release(); globalLease.release()
        return []
    }

    func preparationFailed() async {
        if runtime != nil, prefixValidated { await rollback() }
        else { lease.release(); globalLease.release() }
    }

    func recoverExitCleanup() async {
        let fm = FileManager.default
        guard WineProcesses.ownedGames(runtimeCache: supportRoot.appendingPathComponent("Runtimes")).isEmpty,
              (try? fm.attributesOfItem(atPath: prefix.path)[.type] as? FileAttributeType) == .typeDirectory,
              let id = try? String(contentsOf: prefix.appendingPathComponent(".waypoint-ready-v1"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              id.range(of: "^heroes-[a-f0-9]{64}$", options: .regularExpression) != nil else { return }
        let cached = supportRoot.appendingPathComponent("Runtimes/" + id)
        guard fm.isExecutableFile(atPath: cached.appendingPathComponent("wine/bin/wine").path),
              fm.fileExists(atPath: cached.appendingPathComponent("waypoint-launch-options.exe").path) else { return }
        runtime = cached
        if title != .heroes {
            guard let bridge = target.bridgeResources ?? WindowsRuntime.bridgeResources,
                  let installed = try? WindowsBridge.install(from: bridge, cache: supportRoot.appendingPathComponent("Bridges")) else { return }
            titleHelper = installed
        }
        _ = await gameExited()
    }

    private func findCore(seconds: TimeInterval) async -> Int32? {
        let root = URL(fileURLWithPath: target.install.installPath, isDirectory: true), runtime = wineRoot, title = title
        return await Task.detached {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if let pid = WineProcesses.gameCore(in: root, title: title, runtime: runtime).first { return pid }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return nil
        }.value
    }

    private func rollback() async {
        guard prefixValidated else { lease.release(); globalLease.release(); return }
        // This is exclusively Waypoint's own prefix, under its launch lease.
        // Never target a global wineserver or any existing Battle.net bottle.
        let root = URL(fileURLWithPath: target.install.installPath, isDirectory: true)
        let runtime = wineRoot, wine = wine, helper = try? helperURL(), prefix = prefix, environment = environment, title = title
        await Task.detached {
            let server = runtime.appendingPathComponent("bin/wineserver")
            try? await ChildCommand.run(executable: server, arguments: ["-k"], directory: prefix, environment: environment)
            try? await ChildCommand.run(executable: server, arguments: ["-w"], directory: prefix, environment: environment, timeout: 15)
            if let helper, FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
               WineProcesses.gameAndLaunchers(in: root, title: title, runtime: runtime).isEmpty {
                try? await WindowsLaunchOptions.clear(wine: wine, helper: helper, prefix: prefix, environment: environment, title: title)
            }
        }.value
        lease.release(); globalLease.release()
    }

    private func clear() async throws {
        try await WindowsLaunchOptions.clear(wine: wine, helper: try helperURL(), prefix: prefix, environment: environment, title: title)
    }

    private var wineRoot: URL { metalWineRoot ?? runtime!.appendingPathComponent("wine", isDirectory: true) }
    private var wine: URL { wineRoot.appendingPathComponent("bin/wine") }
    private func helperURL() throws -> URL {
        if title == .heroes, let runtime { return runtime.appendingPathComponent("waypoint-launch-options.exe") }
        guard let titleHelper else { throw WindowsRuntime.Failure.unavailable }
        return titleHelper
    }
    private var environment: [String: String] {
        title.environment(prefix: prefix, wineRoot: wineRoot, display: target.display, graphics: graphics)
    }
}

final class PrefixLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    init(file: URL) throws {
        descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw WindowsHeroes.Failure.busy }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor); descriptor = -1
            throw WindowsHeroes.Failure.busy
        }
    }
    func release() { lock.withLock { if descriptor >= 0 { close(descriptor); descriptor = -1 } } }
    deinit { release() }
}
