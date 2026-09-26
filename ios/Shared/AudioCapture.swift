import AVFoundation
import Foundation

/// iOS mic capture → 16 kHz mono PCM16 (matches Mac STT format).
/// Uses AVAudioEngine only — no Core Audio device list (Mac-only).
@MainActor
public final class AudioCapture {
    public static let sampleRate = PCMWav.defaultSampleRate

    public enum CaptureError: LocalizedError {
        case engineStart(String)
        case noPermission
        public var errorDescription: String? {
            switch self {
            case let .engineStart(m): return m
            case .noPermission: return "Microphone permission denied"
            }
        }
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcm = Data()
    public private(set) var isRecording = false
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { ok in
                cont.resume(returning: ok)
            }
        }
    }

    public func start() throws {
        guard !isRecording else { return }
        pcm = Data()

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: true
        ) else {
            throw CaptureError.engineStart("Could not create 16 kHz PCM format")
        }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            converter.convert(to: out, error: &error, withInputFrom: inputBlock)
            if let error {
                print("AFK AudioCapture convert: \(error)")
                return
            }
            if let channel = out.int16ChannelData?[0] {
                let bytes = Data(bytes: channel, count: Int(out.frameLength) * MemoryLayout<Int16>.size)
                Task { @MainActor in
                    self.pcm.append(bytes)
                    self.onLevel?(Self.rms(bytes))
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStart(error.localizedDescription)
        }
        self.engine = engine
        isRecording = true
    }

    public func stop() -> Data {
        guard isRecording else { return pcm }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        isRecording = false
        let out = pcm
        pcm = Data()
        return out
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
