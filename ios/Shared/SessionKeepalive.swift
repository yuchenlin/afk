import AVFoundation
import Foundation

/// Owns the shared `AVAudioSession` for a dictation session and keeps AFK running in the
/// background with a near-silent looping sine (`UIBackgroundModes: audio`).
///
/// The category is `.playAndRecord` + `.mixWithOthers` for the whole session and must be set
/// while AFK is foreground: from the background iOS refuses both a category switch into a
/// record category (`!int`, 560557684) and a fresh mic start, so `AudioCapture` arms its muted
/// engine on this session at the same time. Mixable, so other apps' audio keeps playing and a
/// background reactivation (after an interruption) is allowed. `.allowBluetoothA2DP` keeps
/// AirPods in music quality for the whole session (input comes from the iPhone mic).
/// `.defaultToSpeaker` keeps mixed audio on the speaker when no headphones are connected.
///
/// Pure digital silence is treated as "not playing" on some iOS builds — hence the sine.
@MainActor
public final class SessionKeepalive {
    private var player: AVAudioPlayer?

    public init() {}

    public var isRunning: Bool { player?.isPlaying == true }

    private static let options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]

    /// Activate the session and start (or resume) the loop.
    public func start() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord || session.mode != .default || session.categoryOptions != Self.options {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.options)
        }
        try session.setActive(true)
        try ensurePlaying()
    }

    public func stop() {
        player?.stop()
        player = nil
    }

    private func ensurePlaying() throws {
        if let player {
            if player.isPlaying { return }
            if player.play() { return }
        }
        let player = try AVAudioPlayer(data: Self.nearSilentSineWav(sampleRate: 16_000, seconds: 1.0, frequency: 40, amplitude: 0.002))
        // Non-zero volume + non-zero PCM — volume 0 / all-zero buffers are ignored
        // by the background-audio assertion on some iOS builds.
        player.volume = 0.05
        player.numberOfLoops = -1
        player.prepareToPlay()
        guard player.play() else {
            throw AudioCapture.CaptureError.engineStart("Silent keepalive failed to play")
        }
        self.player = player
    }

    /// Near-silent PCM16 mono WAV (tiny sine, not digital zero).
    private static func nearSilentSineWav(
        sampleRate: Int,
        seconds: Double,
        frequency: Double,
        amplitude: Double
    ) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        let dataSize = frames * 2
        var data = Data()
        data.reserveCapacity(44 + dataSize)

        func appendUInt32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(1) // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))
        appendUInt16(2) // block align
        appendUInt16(16) // bits
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataSize))

        let twoPiF = 2.0 * Double.pi * frequency
        for i in 0..<frames {
            let sample = sin(twoPiF * Double(i) / Double(sampleRate)) * amplitude
            let clamped = max(-1.0, min(1.0, sample))
            var le = Int16(clamped * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }
}
