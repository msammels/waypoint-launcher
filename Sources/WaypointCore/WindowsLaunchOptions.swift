import Foundation

/// Uses the Windows game's DPAPI channel inside its own Wine user profile.
/// This never reads another prefix or copies a Battle.net account from it.
enum WindowsLaunchOptions {
    static func frame(token: LoginToken, region: Region, locale: String?, launch: Bool = false) throws -> Data {
        let value = token.value
        guard value.utf8.count <= 128, value.utf8.allSatisfy({ $0 >= 32 && $0 <= 126 }),
              LoginToken(value) != nil,
              locale == nil || (locale!.utf8.count == 4 && locale!.utf8.allSatisfy({
                  (65...90).contains($0) || (97...122).contains($0)
              })) else { throw ChildCommand.Failure.invalidInput }
        var frame = Data((launch ? "WAYPOINT-HERO-LAUNCH-1\n" : "WAYPOINT-HERO-1\n").utf8)
        frame.append(contentsOf: value.utf8)
        frame.append(contentsOf: "\n\(region.launchOptionValue)\n\(locale ?? "")\n".utf8)
        return frame
    }

    static func write(token: LoginToken, region: Region, locale: String?, wine: URL,
                      helper: URL, prefix: URL, environment: [String: String], launch: Bool = false) async throws {
        var input = try frame(token: token, region: region, locale: locale, launch: launch)
        defer { input.resetBytes(in: input.startIndex..<input.endIndex) }
        do {
            try await ChildCommand.run(executable: wine, arguments: [helper.path], directory: prefix,
                                       environment: environment, input: input, successStatus: 87,
                                       acknowledgement: Data("ok\n".utf8))
        } catch {
            // Never launch on a failed hand-off, including when clearing the
            // previous account also fails. No fallback token is read here.
            // Cleanup must run even if the launching task was cancelled.
            await Task.detached {
                try? await clear(wine: wine, helper: helper, prefix: prefix, environment: environment)
            }.value
            throw error
        }
    }

    static func clear(wine: URL, helper: URL, prefix: URL, environment: [String: String]) async throws {
        try await ChildCommand.run(executable: wine, arguments: [helper.path], directory: prefix,
                                   environment: environment, input: Data("clear\n".utf8), successStatus: 87,
                                   acknowledgement: Data("ok\n".utf8))
    }
}
