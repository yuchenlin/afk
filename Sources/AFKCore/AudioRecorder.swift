import AudioToolbox
import AVFoundation
import os

private let audioLog = Logger(subsystem: "xyz.yuchenlin.afk", category: "audio")

/// Captures the default microphone as 16 kHz mono PCM16 (the STT model's native format).
/// Callbacks run on the audio thread.
public final class AudioRecorder {
    public enum RecorderError: LocalizedError {
        case noInput
        case unsupportedFormat
        case deviceUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone input available"
            case .unsupportedFormat: return "Microphone format not supported"
            case let .deviceUnavailable(name): return "Couldn't use \(name)"
            }
        }
    }

    public static let sampleRate = 16_000

    /// A fresh engine per recording, so device switches and hot-plugs never leave a stale format.
    private var engine: AVAudioEngine?
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(AudioRecorder.sampleRate),
        channels: 1,
        interleaved: true
    )!
    public init() {}

    /// Records from `device` (nil = system default). `onChunk` receives PCM16 bytes;
    /// `onLevel` receives a 0...1 loudness estimate. Returns the device actually used.
    @discardableResult
    public func start(
        device: AudioInputDevice?,
        onChunk: @escaping @Sendable (Data) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws -> String {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device {
            guard let unit = input.audioUnit else { throw RecorderError.deviceUnavailable(device.name) }
            var id = device.id
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw RecorderError.deviceUnavailable(device.name) }
        }
        let deviceName = device?.name ?? AudioDevices.defaultInputDevice()?.name ?? "default input"
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw RecorderError.noInput }
        guard let converter = AVAudioConverter(from: format, to: target) else {
            throw RecorderError.unsupportedFormat
        }
        converter.downmix = true
        let target = self.target

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            onLevel(Self.level(of: buffer))
            if let data = Self.convert(buffer, with: converter, to: target), !data.isEmpty {
                onChunk(data)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        audioLog.info("recording from \(deviceName, privacy: .public) at \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
        return deviceName
    }

    public func stop() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat
    ) -> Data? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }

    /// RMS mapped from roughly -50…-10 dBFS onto 0…1.
    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += channel[i] * channel[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(1, max(0, (db + 50) / 40))
    }
}
