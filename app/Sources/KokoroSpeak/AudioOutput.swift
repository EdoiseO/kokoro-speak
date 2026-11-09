import AVFoundation

/// Gapless playback of 24 kHz mono PCM chunks with AVAudioEngine.
/// The engine only runs while there is something to play.
final class AudioOutput {
    static let sampleRate = 24_000.0
    /// Kokoro trims silence from each chunk; a short pause keeps sentences from running together.
    private static let pauseSeconds = 0.12

    var onBufferFinished: (() -> Void)?
    private(set) var queuedCount = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioOutput.sampleRate, channels: 1)!
    private var generation = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Queues one WAV chunk from the worker. Returns false if the data isn't valid audio.
    @discardableResult
    func enqueue(wav: Data) -> Bool {
        guard let samples = Self.pcm16Samples(fromWAV: wav), !samples.isEmpty else { return false }
        let padding = Int(Self.sampleRate * Self.pauseSeconds)
        let frames = AVAudioFrameCount(samples.count + padding)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = frames
        for (index, sample) in samples.enumerated() {
            channel[index] = Float(sample) / 32768
        }
        for index in samples.count..<Int(frames) { channel[index] = 0 }

        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        queuedCount += 1
        let current = generation
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, current == self.generation else { return }
                self.queuedCount -= 1
                self.onBufferFinished?()
            }
        }
        if !player.isPlaying { player.play() }
        return true
    }

    /// Stops playback immediately and drops everything queued.
    func stop() {
        generation += 1
        queuedCount = 0
        player.stop()
        engine.stop()
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
