import AVFoundation
import Foundation

/// Mic capture for keyboard dictation → 16 kHz mono PCM16 (matches Mac STT format).
///
/// On device, iOS refuses to *start* mic input once AFK is in the background (`engine.start`
/// fails with `cannotStartRecording` / avfaudio `'what'`), and refuses to switch the session to
/// a record category from the background (`!int`). It does let an input engine that is already
/// running keep going. So the engine is started once while AFK is foreground (`arm()`), with
/// Apple voice processing, and its input is muted at once with `isVoiceProcessingInputMuted`.
/// While muted, the input delivers silence and iOS turns the orange mic indicator off.
/// `open()` unmutes for one utterance — allowed from the background because nothing starts —
/// and `close()` mutes again and returns the PCM. `disarm()` stops the engine.
///
/// The caller owns the `AVAudioSession` (see `SessionKeepalive`): it must already be active in
/// `.playAndRecord` before `arm()`.
@MainActor
public final class AudioCapture {
    public static let sampleRate = PCMWav.defaultSampleRate

    public enum CaptureError: LocalizedError {
        case engineStart(String)
        case noPermission
        /// The muted engine is gone (call, Siri, audio route change) and iOS will not start a
        /// new one while AFK is in the background.
        case backgroundStartBlocked

        public var errorDescription: String? {
            switch self {
            case let .engineStart(m): return m
            case .noPermission: return "Microphone permission denied"
            case .backgroundStartBlocked: return "iOS stopped the AFK mic — open AFK once to turn it back on"
            }
        }
    }

    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var restartTimes: [Date] = []
    private let sink = CaptureSink(sampleRate: PCMWav.defaultSampleRate)

    /// Main actor, ~20 Hz, only while open.
    public var onLevel: ((Float) -> Void)? {
        didSet {
            let handler = onLevel
            sink.levelHandler = handler.map { h in { level in Task { @MainActor in h(level) } } }
        }
    }

    /// Main actor: the armed engine stopped and could not be restarted in place.
    public var onEngineStopped: (() -> Void)?

    public init() {}

    /// Engine is running (muted or open); `open()` will work from the background.
    public var isArmed: Bool { engine?.isRunning == true }

    /// Mic unmuted for an utterance.
    public private(set) var isOpen = false

    /// Input buffers received since `open()` (0 = iOS never delivered input).
    public nonisolated var buffersReceived: Int { sink.bufferCount }

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

    /// Start the voice-processing engine with input muted. Needs AFK in the foreground; a
    /// background attempt throws `.backgroundStartBlocked`. No-op while armed.
    public func arm() throws {
        if isArmed { return }
        disarm()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            throw CaptureError.engineStart("Voice processing unavailable: \(error.localizedDescription)")
        }
        // Keep other apps' audio at full volume while the engine runs.
        input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        // Voice processing runs input and output together; make sure the output side exists.
        _ = engine.mainMixerNode

        try installTap(on: engine)
        input.isVoiceProcessingInputMuted = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Self.map(error)
        }
        input.isVoiceProcessingInputMuted = true
        self.engine = engine
        restartTimes = []
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    /// Restart the existing engine after iOS stopped it (interruption ended, route change).
    /// Returns false when iOS refuses; the caller then disarms.
    @discardableResult
    public func restart() -> Bool {
        guard let engine else { return false }
        if engine.isRunning { return true }
        do {
            try installTap(on: engine)
            engine.inputNode.isVoiceProcessingInputMuted = !isOpen
            engine.prepare()
            try engine.start()
            engine.inputNode.isVoiceProcessingInputMuted = !isOpen
            return true
        } catch {
            return false
        }
    }

    /// iOS stops the engine when the I/O unit is reconfigured (voice processing often does this
    /// right after start, and on route changes). Restart in place a few times before giving up.
    private func handleConfigurationChange() {
        guard let engine, !engine.isRunning else { return }
        let now = Date()
        restartTimes = restartTimes.filter { now.timeIntervalSince($0) < 10 }
        if restartTimes.count < 3 {
            restartTimes.append(now)
            if restart() { return }
        }
        onEngineStopped?()
    }

    /// (Re)install the tap for the input's current format (it can change with the route).
    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
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
    }

    /// Unmute the armed engine and start keeping audio for one utterance.
    public func open() throws {
        if isOpen { return }
        guard let engine, engine.isRunning else { throw CaptureError.backgroundStartBlocked }
        sink.begin()
        engine.inputNode.isVoiceProcessingInputMuted = false
        isOpen = true
    }

    /// Mute again (engine keeps running) and return the utterance PCM.
    @discardableResult
    public func close() -> Data {
        engine?.inputNode.isVoiceProcessingInputMuted = true
        isOpen = false
        return sink.end()
    }

    /// Stop the engine (session end, or before re-arming after iOS stopped it).
    public func disarm() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
        configObserver = nil
        if let engine {
            engine.inputNode.isVoiceProcessingInputMuted = true
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isOpen = false
        _ = sink.end()
    }

    /// Largest absolute sample in PCM16 data, 0…1.
    public nonisolated static func peak(of pcm: Data) -> Float {
        var peak: Int32 = 0
        pcm.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                peak = max(peak, abs(Int32(sample)))
            }
        }
        return Float(peak) / Float(Int16.max)
    }

    private static func map(_ error: Error) -> CaptureError {
        let code = (error as NSError).code
        if code == AVAudioSession.ErrorCode.cannotStartRecording.rawValue
            || code == AVAudioSession.ErrorCode.unspecified.rawValue {
            return .backgroundStartBlocked
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
            // Muted between utterances: skip the conversion work entirely.
            guard sink.isActive else { return }
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
    private var active = false
    private var pcm = Data()
    private var buffers = 0
    private var lastLevel = Date.distantPast
    private let sampleRate: Int

    var levelHandler: ((Float) -> Void)?

    init(sampleRate: Int) {
        self.sampleRate = sampleRate
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    var bufferCount: Int {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }

    func begin() {
        lock.lock()
        pcm = Data()
        pcm.reserveCapacity(sampleRate * 2 * 10)
        buffers = 0
        active = true
        lock.unlock()
    }

    func end() -> Data {
        lock.lock()
        let out = active ? pcm : Data()
        active = false
        pcm = Data()
        lock.unlock()
        return out
    }

    func append(_ bytes: Data) {
        let now = Date()
        var level: Float?
        lock.lock()
        guard active else { lock.unlock(); return }
        pcm.append(bytes)
        buffers += 1
        if now.timeIntervalSince(lastLevel) >= 0.05 {
            lastLevel = now
            level = Self.rms(bytes)
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
