import AVFoundation
import Foundation

/// Session-long mic engine → 16 kHz mono PCM16 (matches Mac STT format).
///
/// iOS lets a backgrounded app *keep* recording under `UIBackgroundModes: audio`, but
/// refuses to *start* a mixable recording from the background (`AVAudioSession.ErrorCode
/// .cannotStartRecording`, OSStatus 561145187 / `!rec`). So the engine is started once in
/// the foreground when the dictation session begins and left running ("hot mic", same as
/// Wispr Flow / Typeless — the orange indicator stays on). Keyboard start/stop only
/// `arm()` / `disarm()` which audio is kept; the engine itself never starts in the background.
///
/// Category is always **mixable** (`.mixWithOthers`) so reactivation never throws OSStatus
/// 560557684 (`!int` = CannotInterruptOthers).
@MainActor
public final class AudioCapture {
    public static let sampleRate = PCMWav.defaultSampleRate

    public enum CaptureError: LocalizedError {
        case engineStart(String)
        case noPermission
        /// iOS refused to start mic input because the host is not in the foreground.
        case needsForeground

        public var errorDescription: String? {
            switch self {
            case let .engineStart(m): return m
            case .noPermission: return "Microphone permission denied"
            case .needsForeground: return "iOS paused the AFK mic — open AFK once to resume"
            }
        }
    }

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let sink = CaptureSink(prerollSeconds: 0.4, sampleRate: PCMWav.defaultSampleRate)

    /// Main actor, ~20 Hz, only while armed.
    public var onLevel: ((Float) -> Void)? {
        didSet {
            let handler = onLevel
            sink.levelHandler = handler.map { h in { level in Task { @MainActor in h(level) } } }
        }
    }

    /// Main actor: engine stopped on its own (route / configuration change).
    public var onEngineStopped: (() -> Void)?

    public init() {}

    /// Engine object reports running (may still be starved of buffers).
    public var isRunning: Bool { engine?.isRunning == true }

    /// Mic buffers arrived within the last 3 s — the keyboard can dictate. Safe off-main
    /// (heartbeat queue); buffers only flow while the engine runs.
    public nonisolated var isDeliveringAudio: Bool { sink.secondsSinceLastBuffer < 3 }

    /// Buffers are being kept for the current utterance.
    public var isRecording: Bool { sink.isArmed }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    public static var hasPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Start the session-long engine. Must succeed while the host is foreground; a start
    /// attempted from the background throws `.needsForeground`. Idempotent.
    public func startEngine() throws {
        if isRunning { return }
        teardownEngine()

        try SessionKeepalive.activateMixableSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw CaptureError.engineStart("No microphone input available")
        }
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.engineStart("Could not create 16 kHz PCM converter")
        }

        input.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat,
            block: Self.makeTapBlock(converter: converter, inputFormat: inputFormat, targetFormat: targetFormat, sink: sink)
        )
        engine.prepare()
        sink.markBuffer()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            sink.clearLiveness()
            throw Self.map(error)
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine?.isRunning != true else { return }
                self.onEngineStopped?()
            }
        }
    }

    /// Stop the engine (session end). Drops any unfinished utterance.
    public func stopEngine() {
        _ = sink.disarm()
        teardownEngine()
        sink.clearLiveness()
    }

    /// Begin keeping audio (includes a short pre-roll so the first syllable is not clipped).
    @discardableResult
    public func arm() -> Bool {
        guard isRunning else { return false }
        sink.arm()
        return true
    }

    /// Stop keeping audio and return the utterance PCM. Engine keeps running.
    public func disarm() -> Data {
        sink.disarm()
    }

    private func teardownEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    private static func map(_ error: Error) -> CaptureError {
        let ns = error as NSError
        if ns.code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue {
            return .needsForeground
        }
        return .engineStart(error.localizedDescription)
    }

    /// Built outside the main actor: the tap runs on a realtime audio thread.
    nonisolated private static func makeTapBlock(
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        sink: CaptureSink
    ) -> AVAudioNodeTapBlock {
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        return { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            // Hand each input buffer to the converter exactly once.
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if error != nil { return }
            guard let channel = out.int16ChannelData?[0], out.frameLength > 0 else { return }
            sink.append(Data(bytes: channel, count: Int(out.frameLength) * MemoryLayout<Int16>.size))
        }
    }
}

/// Thread-safe accumulator shared between the audio tap thread and the main actor.
final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var pcm = Data()
    private var preroll = Data()
    private let prerollBytes: Int
    private var lastBufferAt = Date.distantPast
    private var lastLevel = Date.distantPast

    var levelHandler: ((Float) -> Void)?

    init(prerollSeconds: Double, sampleRate: Int) {
        prerollBytes = Int(prerollSeconds * Double(sampleRate)) * MemoryLayout<Int16>.size
    }

    var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        return armed
    }

    var secondsSinceLastBuffer: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastBufferAt)
    }

    /// Grace period right after engine start, before the first buffer lands.
    func markBuffer() {
        lock.lock()
        lastBufferAt = Date()
        lock.unlock()
    }

    func clearLiveness() {
        lock.lock()
        lastBufferAt = .distantPast
        preroll = Data()
        lock.unlock()
    }

    func arm() {
        lock.lock()
        pcm = preroll
        preroll = Data()
        armed = true
        lock.unlock()
    }

    func disarm() -> Data {
        lock.lock()
        let out = armed ? pcm : Data()
        armed = false
        pcm = Data()
        lock.unlock()
        return out
    }

    func append(_ bytes: Data) {
        let now = Date()
        var level: Float?
        lock.lock()
        lastBufferAt = now
        if armed {
            pcm.append(bytes)
            if now.timeIntervalSince(lastLevel) >= 0.05 {
                lastLevel = now
                level = Self.rms(bytes)
            }
        } else {
            preroll.append(bytes)
            if preroll.count > prerollBytes {
                preroll.removeFirst(preroll.count - prerollBytes)
            }
        }
        let levelHandler = self.levelHandler
        lock.unlock()
        if let level { levelHandler?(level) }
    }

    private static func rms(_ pcm: Data) -> Float {
        guard pcm.count >= 2 else { return 0 }
        let count = pcm.count / 2
        var sum: Float = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = Float(samples[i]) / Float(Int16.max)
                sum += v * v
            }
        }
        return min(1, sqrt(sum / Float(count)) * 4)
    }
}
