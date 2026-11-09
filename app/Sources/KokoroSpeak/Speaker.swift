import AVFoundation
import Foundation
import os

let log = Logger(subsystem: "com.kokorospeak.KokoroSpeak", category: "speech")

/// Drives one utterance at a time: asks the worker for chunks, keeps at most
/// two chunks queued ahead of playback, tracks which word is being spoken,
/// and unloads the model when idle.
final class Speaker {
    enum State: Equatable {
        case idle
        case loading
        case speaking
        case failed(String)
    }

    /// What the UI shows while speaking. Ranges are NSString (UTF-16) ranges into `text`.
    struct Snapshot {
        let text: NSString
        let chunkRange: NSRange
        let wordRange: NSRange?
        let fraction: Double
        let secondsLeft: Double?
        let isPaused: Bool
        /// True while the model loads, or when playback has caught up with generation.
        let isWaiting: Bool
    }

    private struct Word {
        let range: NSRange
        let start: Double
        let end: Double
    }

    private struct Chunk {
        let id: Int
        let buffer: AVAudioPCMBuffer
        let textRange: NSRange
        let words: [Word]
        var start: Double = 0
        var duration: Double { Double(buffer.frameLength) / AudioOutput.sampleRate }
    }

    static let maxTextLength = 200_000
    static let protocolVersion = 3
    /// How long the model stays in memory after the last utterance.
    static let keepLoadedSeconds: TimeInterval = 5 * 60

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            log.info("state \(String(describing: self.state), privacy: .public)")
            onStateChange?(state)
        }
    }
    var isBusy: Bool { state == .loading || state == .speaking }
    var isPaused: Bool { audio.isPaused }

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

    private var text: NSString = ""
    private var queue: [Chunk] = []
    private var nextChunkID = 0
    private var lastChunkRange = NSRange(location: 0, length: 0)
    /// Characters skipped or finished, for progress.
    private var finishedCharacters = 0
    /// All audio generated so far, which gives the speaking rate for this voice and speed.
    private var generatedSeconds = 0.0
    private var generatedCharacters = 0
    /// The time-left value last shown, so it counts down steadily instead of jumping.
    private var shownSecondsLeft: Double?
    private var shownAt = Date()
    private var speed = 1.0

    init() {
        worker.onMessage = { [weak self] in self?.handle($0) }
        worker.onExit = { [weak self] in self?.workerExited() }
        audio.onChunkFinished = { [weak self] in self?.chunkFinished($0) }
    }

    // MARK: - Controls

    func speak(_ newText: String, voice: String, speed: Double) {
        stop()
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fail("Select some text first") }
        guard newText.count <= Self.maxTextLength else { return fail("That selection is too long") }
        guard Runtime.isInstalled else { return fail("Kokoro isn't installed. Run install.sh") }

        idleTimer?.invalidate()
        requestCounter += 1
        let request = "r\(requestCounter)"
        currentRequest = request
        generationDone = false
        text = newText as NSString
        self.speed = speed
        state = .loading
        withWorker { [weak self] in
            guard let self, self.currentRequest == request else { return }
            self.sendTracked(["action": "start", "requestId": request, "text": newText,
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
        clearPlayback()
        if isBusy { state = .idle }
        scheduleUnload()
    }

    /// Shows a message in the menu bar icon's tooltip and menu.
    func report(_ reason: String) {
        stop()
        fail(reason)
    }

    func togglePause() {
        guard state == .speaking else { return }
        if audio.isPaused { audio.resume() } else { audio.pause() }
    }

    /// Skips the rest of the chunk (sentence) being spoken.
    func skip() {
        guard state == .speaking, !queue.isEmpty else { return }
        let skipped = queue.removeFirst()
        finishedCharacters += skipped.textRange.length
        audio.reset()
        for index in queue.indices {
            guard let start = audio.schedule(queue[index].buffer, id: queue[index].id) else { return fail("Couldn't play audio") }
            queue[index].start = start
        }
        if queue.isEmpty && generationDone { finish() } else { requestNextIfNeeded() }
    }

    func snapshot() -> Snapshot? {
        guard isBusy else { return nil }
        let time = audio.currentTime
        let chunk = queue.first { time < $0.start + $0.duration } ?? queue.last
        let waiting = state == .loading || queue.last.map { time >= $0.start + $0.duration - 0.05 } ?? true
        var chunkRange = chunk?.textRange ?? lastChunkRange
        if chunk == nil && chunkRange.length == 0 {
            // Nothing played yet: preview the start of the selection while the model loads.
            chunkRange = NSRange(location: 0, length: min(text.length, 200))
        }
        var wordRange: NSRange?
        if let chunk {
            let offset = time - chunk.start
            wordRange = (chunk.words.last { $0.start <= offset } ?? chunk.words.first)?.range
        }
        let position = wordRange.map { NSMaxRange($0) } ?? chunkRange.location
        let total = max(text.length, 1)
        let fraction = min(Double(position) / Double(total), 1)

        let secondsLeft = state == .speaking ? smoothedSecondsLeft(at: time, waiting: waiting) : nil
        return Snapshot(text: text, chunkRange: chunkRange, wordRange: wordRange,
                        fraction: fraction, secondsLeft: secondsLeft, isPaused: audio.isPaused,
                        isWaiting: waiting && !audio.isPaused)
    }

    /// Audio already queued is known exactly; text not yet generated is estimated from
    /// the rate measured so far. The shown value counts down in real time and eases
    /// toward that estimate, so it doesn't jump with every word.
    private func smoothedSecondsLeft(at time: Double, waiting: Bool) -> Double {
        let queued = queue.reduce(0.0) { total, chunk in
            total + max(0, chunk.start + chunk.duration - max(time, chunk.start))
        }
        let notGenerated = Double(max(text.length - NSMaxRange(lastChunkRange), 0))
        let rate = generatedSeconds > 0 && generatedCharacters > 0
            ? Double(generatedCharacters) / generatedSeconds : 14 * speed
        let estimate = queued + notGenerated / rate

        let now = Date()
        defer { shownAt = now }
        guard var shown = shownSecondsLeft else {
            shownSecondsLeft = estimate
            return estimate
        }
        if !audio.isPaused && !waiting { shown -= now.timeIntervalSince(shownAt) }
        let gap = estimate - shown
        if abs(gap) > 1.5 { shown += gap * 0.08 }
        shownSecondsLeft = max(shown, 0)
        return max(shown, 0)
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
            if event == "ready", (message["protocolVersion"] as? Int) == Self.protocolVersion {
                workerReady = true
                let action = whenReady
                whenReady = nil
                action?()
            } else {
                fail(event == "ready" ? "Kokoro's runtime is out of date. Run install.sh" : "Kokoro couldn't load its model")
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
            if queue.isEmpty { finish() }
            return
        }
        let textRange = Self.range(result["textStart"], result["textEnd"])
        if result["skipped"] as? Bool == true {
            finishedCharacters += textRange.length
        } else {
            guard let encoded = result["audioBase64"] as? String,
                  let wav = Data(base64Encoded: encoded),
                  let buffer = audio.makeBuffer(wav: wav) else { return fail("Couldn't play Kokoro's audio") }
            let words = (result["words"] as? [[Any]] ?? []).compactMap { item -> Word? in
                guard item.count == 4, let start = item[2] as? Double, let end = item[3] as? Double else { return nil }
                return Word(range: Self.range(item[0], item[1]), start: start, end: end)
            }
            nextChunkID += 1
            var chunk = Chunk(id: nextChunkID, buffer: buffer, textRange: textRange, words: words)
            guard let start = audio.schedule(buffer, id: chunk.id) else { return fail("Couldn't play audio") }
            chunk.start = start
            queue.append(chunk)
            generatedSeconds += chunk.duration
            generatedCharacters += textRange.length
            lastChunkRange = textRange
            state = .speaking
        }
        requestNextIfNeeded()
    }

    private static func range(_ start: Any?, _ end: Any?) -> NSRange {
        let location = start as? Int ?? 0
        return NSRange(location: location, length: max((end as? Int ?? location) - location, 0))
    }

    private func requestNextIfNeeded() {
        guard let request = currentRequest, outstandingRPC == nil, !generationDone,
              queue.count < 2 else { return }
        sendTracked(["action": "next", "requestId": request])
    }

    private func chunkFinished(_ id: Int) {
        guard currentRequest != nil, let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let chunk = queue.remove(at: index)
        finishedCharacters += chunk.textRange.length
        if generationDone && queue.isEmpty { finish() } else { requestNextIfNeeded() }
    }

    private func clearPlayback() {
        audio.shutdown()
        queue.removeAll()
        finishedCharacters = 0
        generatedSeconds = 0
        generatedCharacters = 0
        shownSecondsLeft = nil
        lastChunkRange = NSRange(location: 0, length: 0)
    }

    private func finish() {
        currentRequest = nil
        outstandingRPC = nil
        clearPlayback()
        state = .idle
        scheduleUnload()
    }

    private func fail(_ reason: String) {
        currentRequest = nil
        outstandingRPC = nil
        whenReady = nil
        clearPlayback()
        state = .failed(reason)
        scheduleUnload()
    }
}
