import Foundation
import Testing
@testable import WaypointCore

@Test func connectionFailuresBackOffAndEventuallyRecover() async throws {
    var retry = NetworkRetry(delays: [.zero, .zero, .zero])
    retry.sleep = { _ in }
    var attempts = 0
    let result = try await retry.run { _ in
        attempts += 1
        if attempts < 3 { throw URLError(.networkConnectionLost) }
        return "finished"
    }
    #expect(result == "finished")
    #expect(attempts == 3)
}

@Test func retriesAreBoundedAndExcludePermanentErrorsAndCancellation() async {
    let retry = NetworkRetry(delays: [.zero, .zero])
    for (error, expectedAttempts): (any Error, Int) in [
        (URLError(.networkConnectionLost), 3),
        (URLError(.notConnectedToInternet), 3),
        (URLError(.cancelled), 1),
        (URLError(.serverCertificateUntrusted), 1),
        (CocoaError(.fileWriteOutOfSpace), 1),
        (CancellationError(), 1),
    ] {
        var attempts = 0
        do {
            _ = try await retry.run { _ -> Int in attempts += 1; throw error }
            Issue.record("Expected a failure")
        } catch {}
        #expect(attempts == expectedAttempts)
    }
}

@Test func offlineRequestsUseBoundedRetriesInsteadOfAResourceTimeoutWait() {
    #expect(!VersionService.defaultSession.configuration.waitsForConnectivity)
}

@Test func cancellationStopsLocalHashingBeforeReadingFiles() async {
    let work = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try GameUpdater.md5(of: URL(fileURLWithPath: "/nonexistent/should-not-be-opened"))
    }
    do {
        _ = try await work.value
        Issue.record("Expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
}

@Test func cancellationDuringBackoffStopsTheOperation() async {
    let retry = NetworkRetry(delays: [.seconds(30)], sleep: { _ in throw CancellationError() })
    var attempts = 0
    do {
        _ = try await retry.run { _ -> Int in attempts += 1; throw URLError(.networkConnectionLost) }
        Issue.record("Expected cancellation")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(attempts == 1)
}

@Test func errorMessagesHideDownloadInternalsAndPreserveUsefulErrors() {
    let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [
        NSLocalizedDescriptionKey: "The network connection was lost.",
        NSURLSessionDownloadTaskResumeData: Data(repeating: 42, count: 10_000),
        NSURLErrorFailingURLStringErrorKey: "https://cdn.example/internal/archive",
    ])
    #expect(errorMessage(error) == "The connection was lost. Try again to continue.")
    #expect(errorMessage(UpdateError.gameRunning) == "Quit the game before updating")
    #expect(errorMessage(TACTError.notFound("https://cdn.example/internal/archive")) ==
            "A required file is unavailable on the download server. Try again later.")
    #expect(errorMessage(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "One\nline"] )) == "One line")
}

/// A real HTTP server exercises Foundation's on-disk downloads and resume
/// data, which URLProtocol stubs cannot faithfully reproduce. Python ships
/// with the Xcode command line tools already required to build this package.
final class DownloadServer {
    let directory: URL
    let process = Process()
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("waypoint-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.script, directory.path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line += byte }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate()
            process.waitUntilExit()
            throw TACTError.malformed("test HTTP server address")
        }
        url = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    func requests() throws -> [[String: String]] {
        let log = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
        return try log.split(separator: "\n").map {
            try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
        }
    }

    func client(_ modes: [String], limiter: DownloadBandwidthLimiter? = nil) -> CDNClient {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        var client = CDNClient(product: "test", path: "tpr/test", servers: modes.map { url.appendingPathComponent($0) }, session: session)
        client.bandwidthLimiter = limiter ?? DownloadBandwidthLimiter()
        client.retry.delays = [.zero, .zero, .zero]
        return client
    }

    static let payload = Data((0..<(2 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0) })

    private static let script = #"""
    import http.server, json, pathlib, socket, sys, time
    root = pathlib.Path(sys.argv[1])
    payload = bytes(range(256)) * 8192
    counts = {}
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_GET(self):
            mode = self.path.split('/')[1]
            counts[mode] = counts.get(mode, 0) + 1
            range_header = self.headers.get('Range', '')
            with (root / 'requests.jsonl').open('a') as log:
                log.write(json.dumps({'mode': mode, 'range': range_header, 'file': self.path.split('/')[-1]}) + '\n')
            if mode == 'fixtures':
                data = (root / 'fixtures' / self.path.split('/')[-1]).read_bytes()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                if counts[mode] == 2:
                    self.wfile.write(data[:1024])
                    self.wfile.flush()
                    while not (root / 'release').exists(): time.sleep(0.01)
                    data = data[1024:]
                try: self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError): pass
                return
            status = 416 if mode == 'stale' and range_header else 404 if mode == 'missing' else 503 if mode == 'busy' and counts[mode] < 3 else 200
            if status != 200:
                self.send_response(status)
                self.send_header('Content-Length', '0')
                self.end_headers()
                return
            start, end = 0, len(payload) - 1
            if range_header:
                first, last = range_header.removeprefix('bytes=').split('-')
                start, end = int(first), int(last) if last else end
            self.send_response(206 if range_header else 200)
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('ETag', '"fixture-v1"')
            self.send_header('Content-Length', str(end - start + 1))
            if range_header:
                actual_start = start + 1 if mode == 'wrong-range' else start
                self.send_header('Content-Range', f'bytes {actual_start}-{end}/{len(payload)}')
            self.end_headers()
            if mode in ['drop', 'drop-range', 'stale'] and counts[mode] == 1:
                partial_size = 32768 if mode == 'drop-range' else 1024 * 1024
                self.wfile.write(payload[start:start + partial_size])
                self.wfile.flush()
                time.sleep(0.05)
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()
            else:
                try: self.wfile.write(payload[start:end + 1])
                except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
    """#
}

@Test func cdnTriesAnotherMirrorAndRetriesTemporaryServerFailures() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["missing", "busy"])
    defer { client.session.invalidateAndCancel() }
    let data = try await client.fetch(.data, "aabb")
    #expect(data == DownloadServer.payload)
    let requests = try server.requests()
    #expect(requests.filter { $0["mode"] == "missing" }.count == 1)
    #expect(requests.filter { $0["mode"] == "busy" }.count == 3)
}

@Test func cdnResumesAnInterruptedWholeFile() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["drop"])
    defer { client.session.invalidateAndCancel() }
    let file = try await client.download(.data, "aabb")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Data(contentsOf: file) == DownloadServer.payload)
    let requests = try server.requests()
    #expect(requests.count >= 2)
    #expect(requests.first?["range"] == "")
    #expect(requests.dropFirst().contains { request in
        guard let range = request["range"], range.hasPrefix("bytes="),
              let start = Int(range.dropFirst(6).split(separator: "-")[0]) else { return false }
        return start > 0 && start <= 1024 * 1024
    }, "Requests: \(requests)")
}

@Test func archiveRetriesKeepTheOriginalBoundedRange() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["drop-range"])
    defer { client.session.invalidateAndCancel() }
    let file = try await client.download(.data, "aabb", range: 32768...98303)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Data(contentsOf: file) == DownloadServer.payload[32768...98303])
    let requests = try server.requests()
    #expect(requests.count >= 2)
    #expect(requests.allSatisfy { $0["range"] == "bytes=32768-98303" })
}

@Test func cdnRestartsAFileWhenTheServerRejectsResume() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["stale"])
    defer { client.session.invalidateAndCancel() }
    let file = try await client.download(.data, "aabb")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(try Data(contentsOf: file) == DownloadServer.payload)
    let requests = try server.requests()
    #expect(requests.contains { !($0["range"] ?? "").isEmpty })
    #expect(requests.last?["range"] == "")
}

@Test func archiveRejectsAResponseForTheWrongRange() async throws {
    let server = try DownloadServer()
    defer { server.stop() }
    let client = server.client(["wrong-range"])
    defer { client.session.invalidateAndCancel() }
    do {
        let file = try await client.download(.data, "aabb", range: 32768...98303)
        try? FileManager.default.removeItem(at: file)
        Issue.record("Expected a range mismatch")
    } catch {
        #expect(error is TACTError)
    }
    #expect(try server.requests().count == 1)
}

@Test func failedResumeFallbackDoesNotDownloadTheFileTwice() async throws {
    let stale = FileManager.default.temporaryDirectory.appendingPathComponent("resume-test-\(UUID().uuidString)")
    try Data().write(to: stale)
    defer { try? FileManager.default.removeItem(at: stale) }
    let response = HTTPURLResponse(url: URL(string: "https://cdn.example/file")!, statusCode: 416,
                                   httpVersion: nil, headerFields: nil)!
    var attempts: [Bool] = []
    do {
        _ = try await CDNClient.resumeOrRestart(Data([1])) { resumeData in
            attempts.append(resumeData != nil)
            if resumeData != nil { return (stale, response) }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        Issue.record("Expected the fresh fallback to fail")
    } catch {
        #expect((error as NSError).domain == NSCocoaErrorDomain)
        #expect((error as NSError).code == CocoaError.fileWriteOutOfSpace.rawValue)
    }
    #expect(attempts == [true, false])
    #expect(!FileManager.default.fileExists(atPath: stale.path))
}
