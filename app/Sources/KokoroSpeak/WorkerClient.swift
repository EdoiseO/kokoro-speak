import Foundation

/// Where the Python runtime lives. Override with KOKORO_SPEAK_RUNTIME for development.
enum Runtime {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["KOKORO_SPEAK_RUNTIME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Kokoro Speak", isDirectory: true)
    }
    static var python: URL { root.appendingPathComponent(".venv/bin/python") }
    static var worker: URL { root.appendingPathComponent("worker.py") }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: worker.path)
    }
}

/// Runs the Kokoro worker as a child process and exchanges JSON lines with it.
/// All callbacks are delivered on the main queue.
final class WorkerClient {
    /// Everything allowed except network access, so the model can never phone home.
    private static let sandboxProfile = "(version 1)(allow default)(deny network*)"

    var onMessage: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        stop()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.sandboxProfile, Runtime.python.path, "-u", Runtime.worker.path]
        process.currentDirectoryURL = Runtime.root
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self, self.process === finished else { return }
                self.process = nil
                self.input = nil
                self.buffer.removeAll()
                self.onExit?()
            }
        }

        try process.run()
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
    }

    func send(_ message: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        // SIGPIPE is ignored app-wide, so a dead worker surfaces as a thrown error here.
        try? input.write(contentsOf: data)
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        input = nil
        buffer.removeAll()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let object = try? JSONSerialization.jsonObject(with: line),
               let message = object as? [String: Any] {
                onMessage?(message)
            }
        }
    }
}
