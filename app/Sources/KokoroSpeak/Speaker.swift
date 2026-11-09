import Foundation

/// Drives one utterance at a time: asks the worker for chunks, keeps at most
/// two chunks queued ahead of playback, and unloads the model when idle.
final class Speaker {
    enum State: Equatable {
        case idle
        case loading
        case speaking
        case failed(String)
    }

    static let maxTextLength = 200_000
    /// How long the model stays in memory after the last utterance.
    static let keepLoadedSeconds: TimeInterval = 5 * 60

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var isBusy: Bool { state == .loading || state == .speaking }

    private let worker = WorkerClient()
    private let audio = AudioOutput()
    private var workerReady = false
    private var whenReady: (() -> Void)?

    private var nextRPC = 1
    private var requestCounter = 0
    private var currentRequest: String?
    private var outstandingRPC: Int?
    private var generationDone = false
    private var idleTimer: Timer?

    init() {
        worker.onMessage = { [weak self] in self?.handle($0) }
        worker.onExit = { [weak self] in self?.workerExited() }
        audio.onBufferFinished = { [weak self] in self?.bufferFinished() }
    }

    func speak(_ text: String, voice: String, speed: Double) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fail("Select some text first") }
        guard text.count <= Self.maxTextLength else { return fail("That selection is too long") }
        guard Runtime.isInstalled else { return fail("Kokoro isn't installed. Run install.sh") }

        idleTimer?.invalidate()
        requestCounter += 1
        let request = "r\(requestCounter)"
        currentRequest = request
        generationDone = false
        state = .loading
        withWorker { [weak self] in
            guard let self, self.currentRequest == request else { return }
            self.sendTracked(["action": "start", "requestId": request, "text": text,
                              "voice": voice, "speed": speed])
        }
    }

    func stop() {
        if let request = currentRequest {
            worker.send(["rpcId": takeRPC(), "action": "cancel", "requestId": request])
        }
        currentRequest = nil
        outstandingRPC = nil
        whenReady = nil
        audio.stop()
        if isBusy { state = .idle }
        scheduleUnload()
    }

    // MARK: - Worker lifecycle

    private func withWorker(_ action: @escaping () -> Void) {
        if worker.isRunning && workerReady { return action() }
        whenReady = action
        if !worker.isRunning {
            workerReady = false
            do { try worker.start() } catch { fail("Couldn't start Kokoro") }
        }
    }

    private func scheduleUnload() {
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.keepLoadedSeconds, repeats: false) { [weak self] _ in
            guard let self, !self.isBusy else { return }
            self.workerReady = false
            self.worker.stop()
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func workerExited() {
        workerReady = false
        if currentRequest != nil { fail("Kokoro stopped unexpectedly") }
    }

    // MARK: - Protocol

    private func takeRPC() -> Int {
        defer { nextRPC += 1 }
        return nextRPC
    }

    private func sendTracked(_ fields: [String: Any]) {
        let rpc = takeRPC()
        outstandingRPC = rpc
        var message = fields
        message["rpcId"] = rpc
        worker.send(message)
    }

    private func handle(_ message: [String: Any]) {
        if let event = message["event"] as? String {
            if event == "ready", (message["protocolVersion"] as? Int) == 2 {
                workerReady = true
                let action = whenReady
                whenReady = nil
                action?()
            } else {
                fail("Kokoro couldn't load its model")
            }
            return
        }
        guard let rpc = message["rpcId"] as? Int, rpc == outstandingRPC, currentRequest != nil else { return }
        outstandingRPC = nil

        if let error = message["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "SPEECH_FAILED"
            if code != "CANCELED" { fail("Kokoro couldn't speak that (\(code))") }
            return
        }
        guard let result = message["result"] as? [String: Any] else { return fail("Kokoro sent no result") }

        if result["done"] as? Bool == true {
            generationDone = true
            if audio.queuedCount == 0 { finish() }
            return
        }
        if result["skipped"] as? Bool != true {
            guard let encoded = result["audioBase64"] as? String,
                  let wav = Data(base64Encoded: encoded),
                  audio.enqueue(wav: wav) else { return fail("Couldn't play Kokoro's audio") }
            state = .speaking
        }
        requestNextIfNeeded()
    }

    private func requestNextIfNeeded() {
        guard let request = currentRequest, outstandingRPC == nil, !generationDone,
              audio.queuedCount < 2 else { return }
        sendTracked(["action": "next", "requestId": request])
    }

    private func bufferFinished() {
        guard currentRequest != nil else { return }
        if generationDone && audio.queuedCount == 0 { finish() } else { requestNextIfNeeded() }
    }

    private func finish() {
        currentRequest = nil
        outstandingRPC = nil
        audio.stop()
        state = .idle
        scheduleUnload()
    }

    private func fail(_ reason: String) {
        currentRequest = nil
        outstandingRPC = nil
        whenReady = nil
        audio.stop()
        state = .failed(reason)
        scheduleUnload()
    }
}
