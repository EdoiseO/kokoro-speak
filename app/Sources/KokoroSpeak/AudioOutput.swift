import AVFoundation

/// Gapless playback of 24 kHz mono chunks on one timeline.
///
/// Each chunk is scheduled at an exact sample position, so `currentTime` can be
/// mapped back to the word being spoken. The engine only runs while speaking.
final class AudioOutput {
    static let sampleRate = 24_000.0
    /// Kokoro trims silence from each chunk; a short pause keeps sentences from running together.
    private static let pauseSeconds = 0.12

    /// Called on the main queue with the id passed to `schedule` once that chunk has played.
    var onChunkFinished: ((Int) -> Void)?
    private(set) var isPaused = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioOutput.sampleRate, channels: 1)!
    private var generation = 0
    private var nextStart: AVAudioFramePosition = 0
    private var pausedAt: AVAudioFramePosition = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Seconds on the playback timeline. Frozen while paused.
    var currentTime: Double { Double(currentSample()) / Self.sampleRate }

    /// Decodes a PCM16 WAV chunk into a buffer, with a short pause appended.
    func makeBuffer(wav: Data) -> AVAudioPCMBuffer? {
        guard let samples = Self.pcm16Samples(fromWAV: wav), !samples.isEmpty else { return nil }
        let padding = Int(Self.sampleRate * Self.pauseSeconds)
        let frames = AVAudioFrameCount(samples.count + padding)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / 32768
        }
        for index in samples.count..<Int(frames) { channel[index] = 0 }
        return buffer
    }

    /// Schedules a buffer right after the previous one and returns its start time in seconds.
    func schedule(_ buffer: AVAudioPCMBuffer, id: Int) -> Double? {
        if !engine.isRunning {
            do { try engine.start() } catch { return nil }
        }
        if !player.isPlaying && !isPaused { player.play() }
        let earliest = currentSample() + AVAudioFramePosition(Self.sampleRate * 0.03)
        let start = max(nextStart, earliest)
        nextStart = start + AVAudioFramePosition(buffer.frameLength)
        let current = generation
        player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: start, atRate: Self.sampleRate),
                              options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.onChunkFinished?(id)
            }
        }
        return Double(start) / Self.sampleRate
    }

    func pause() {
        guard !isPaused else { return }
        pausedAt = currentSample()
        isPaused = true
        player.pause()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        player.play()
    }

    /// Drops everything scheduled and restarts the timeline at zero. The engine keeps running.
    func reset() {
        generation += 1
        player.stop()
        nextStart = 0
        pausedAt = 0
        isPaused = false
    }

    /// Stops playback and releases the audio hardware.
    func shutdown() {
        reset()
        engine.stop()
    }

    private func currentSample() -> AVAudioFramePosition {
        if isPaused { return pausedAt }
        guard player.isPlaying, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, playerTime.sampleTime)
    }

    /// Reads the PCM16 "data" chunk of a mono WAV file.
    static func pcm16Samples(fromWAV data: Data) -> [Int16]? {
        let bytes = [UInt8](data)
        guard bytes.count > 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = u32(offset + 4)
            let body = offset + 8
            if bytes[offset..<offset + 4] == [0x64, 0x61, 0x74, 0x61] {  // "data"
                let end = min(body + size, bytes.count)
                var samples = [Int16]()
                samples.reserveCapacity((end - body) / 2)
                var index = body
                while index + 1 < end {
                    samples.append(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8))
                    index += 2
                }
                return samples
            }
            offset = body + size + (size & 1)
        }
        return nil
    }
}
