import Foundation

/// Uses the Windows game's DPAPI channel inside its own Wine user profile.
/// This never reads another prefix or copies a Battle.net account from it.
enum WindowsLaunchOptions {
    static func prepare(wine: URL, helper: URL, prefix: URL, environment: [String: String], title: WindowsTitle = .heroes) async throws {
        try await ChildCommand.run(executable: wine, arguments: [helper.path], directory: prefix,
                                   environment: environment, input: control("prepare", title: title), successStatus: 87,
                                   acknowledgement: Data("ok\n".utf8))
    }

    static func frame(token: LoginToken, region: Region, locale: String?, launch: Bool = false,
                      title: WindowsTitle = .heroes) throws -> Data {
        let value = token.value
        guard value.utf8.count <= 128, value.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              LoginToken(value) != nil,
              locale == nil || (locale!.utf8.count == 4 && locale!.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
              })) else { throw ChildCommand.Failure.invalidInput }
        var frame = title == .heroes
            ? Data((launch ? "WAYPOINT-HERO-LAUNCH-1\n" : "WAYPOINT-HERO-1\n").utf8)
            : control(launch ? "launch" : "write", title: title)
        frame.append(contentsOf: value.utf8)
        frame.append(contentsOf: "\n\(region.launchOptionValue)\n\(locale ?? "")\n".utf8)
        return frame
    }

    static func write(token: LoginToken, region: Region, locale: String?, wine: URL,
                      helper: URL, prefix: URL, environment: [String: String], launch: Bool = false,
                      title: WindowsTitle = .heroes) async throws {
        var input = try frame(token: token, region: region, locale: locale, launch: launch, title: title)
        defer { input.resetBytes(in: input.startIndex..<input.endIndex) }
        do {
            try await ChildCommand.run(executable: wine, arguments: [helper.path], directory: prefix,
                                       environment: environment, input: input, successStatus: 87,
                                       acknowledgement: Data("ok\n".utf8), completeOnCancellation: launch)
        } catch {
            // In launch mode a timeout may follow CreateProcessW. The owned
            // runner must reconcile/stop its prefix before token cleanup;
            // clearing here could race a child that is already starting.
            if launch { throw error }
            // Cleanup must run even if the launching task was cancelled.
            await Task.detached {
                try? await clear(wine: wine, helper: helper, prefix: prefix, environment: environment, title: title)
            }.value
            throw error
        }
    }

    static func clear(wine: URL, helper: URL, prefix: URL, environment: [String: String], title: WindowsTitle = .heroes) async throws {
        try await ChildCommand.run(executable: wine, arguments: [helper.path], directory: prefix,
                                   environment: environment, input: control("clear", title: title), successStatus: 87,
                                   acknowledgement: Data("ok\n".utf8))
    }

    static func control(_ action: String, title: WindowsTitle) -> Data {
        Data((title == .heroes ? "\(action)\n" : "WAYPOINT-WINDOWS-2\n\(title.rawValue)\n\(action)\n").utf8)
    }
}
