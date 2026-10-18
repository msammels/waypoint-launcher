import Foundation
import Testing
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
