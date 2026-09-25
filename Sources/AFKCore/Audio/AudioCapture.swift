import Foundation

#if canImport(AVFoundation)
import AVFoundation
#endif

/// Push-to-talk PCM capture. Real AVAudioEngine wiring lands on macOS build machines.
public protocol AudioCapturing: AnyObject {
    var isCapturing: Bool { get }
    func start() throws
    func stop() -> Data
}

/// Placeholder capture that records silence-sized buffers for UI/pipeline wiring.
public final class AudioCapture: AudioCapturing, @unchecked Sendable {
    public private(set) var isCapturing = false
    private var chunks: [Data] = []
    private let lock = NSLock()

    public init() {}

    public func start() throws {
        lock.lock(); defer { lock.unlock() }
        isCapturing = true
        chunks.removeAll(keepingCapacity: true)
    }

    public func appendForTesting(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard isCapturing else { return }
        chunks.append(data)
    }

    public func stop() -> Data {
        lock.lock(); defer { lock.unlock() }
        isCapturing = false
        let out = chunks.reduce(into: Data()) { $0.append($1) }
        chunks.removeAll(keepingCapacity: true)
        return out
    }
}
