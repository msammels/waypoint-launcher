import Foundation
import Darwin

/// A bounded, awaited child. Secrets can only enter through its stdin pipe;
/// neither its output nor its arguments are included in errors or logs.
enum ChildCommand {
    enum Failure: Error, Equatable { case timedOut, failed(Int32), invalidInput, invalidAcknowledgement }

    static func run(executable: URL, arguments: [String], directory: URL,
                    environment: [String: String], input: Data = Data(),
                    timeout: TimeInterval = 30, successStatus: Int32 = 0,
                    acknowledgement: Data? = nil, completeOnCancellation: Bool = false) async throws {
        guard input.count <= 1024, (acknowledgement?.count ?? 0) <= 64 else { throw Failure.invalidInput }
        if completeOnCancellation { try Task.checkCancellation() }
        let child = Child()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    do {
                        try child.run(executable: executable, arguments: arguments, directory: directory,
                                      environment: environment, input: input, timeout: timeout,
                                      successStatus: successStatus, acknowledgement: acknowledgement)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            if !completeOnCancellation { try Task.checkCancellation() }
        } onCancel: {
            if !completeOnCancellation { child.cancel() }
        }
    }

    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private let process = Process()
        private var cancelled = false

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        func run(executable: URL, arguments: [String], directory: URL,
                 environment: [String: String], input: Data, timeout: TimeInterval,
                 successStatus: Int32, acknowledgement: Data?) throws {
            let pipe = Pipe()
            let output = acknowledgement == nil ? nil : Pipe()
            for handle in [pipe.fileHandleForReading, pipe.fileHandleForWriting,
                           output?.fileHandleForReading, output?.fileHandleForWriting].compactMap({ $0 }) {
                _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
            }
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            defer {
                try? pipe.fileHandleForWriting.close()
                try? pipe.fileHandleForReading.close()
                try? output?.fileHandleForWriting.close()
                try? output?.fileHandleForReading.close()
            }
            let exited = DispatchSemaphore(value: 0)
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = directory
            process.environment = environment
            process.standardInput = pipe
            if let output { process.standardOutput = output }
            else { process.standardOutput = FileHandle.nullDevice }
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in exited.signal() }
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            do { try process.run() } catch { lock.unlock(); throw error }
            lock.unlock()
            // The whole protocol fits in the pipe buffer. The helper receives
            // EOF even on failure; it never waits for an interactive terminal.
            do {
                try pipe.fileHandleForWriting.write(contentsOf: input)
                try pipe.fileHandleForWriting.close()
            } catch {
                cancel()
                process.waitUntilExit()
                throw error
            }
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                cancel()
                process.waitUntilExit()
                throw Failure.timedOut
            }
            process.waitUntilExit()
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { throw CancellationError() }
            guard process.terminationReason == .exit, process.terminationStatus == successStatus else {
                throw Failure.failed(process.terminationStatus)
            }
            if let output, let acknowledgement {
                // Read only bytes already available after the child exited.
                // Wine services may retain stdout, so never wait for EOF.
                let fd = output.fileHandleForReading.fileDescriptor
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var bytes = [UInt8](repeating: 0, count: 65)
                let count = read(fd, &bytes, bytes.count)
                guard count >= 0, Data(bytes.prefix(max(count, 0))) == acknowledgement else {
                    throw Failure.invalidAcknowledgement
                }
            }
        }
    }
}
