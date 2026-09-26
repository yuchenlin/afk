import AVFoundation
import Foundation

/// Keeps `UIBackgroundModes: audio` honest while a dictation session is active.
///
/// Activating `AVAudioSession` alone does **not** prevent suspension. iOS only
/// keeps the process running when audio is actually playing or recording.
/// Without this, Darwin notifies and the command poll timer never fire once the
/// user leaves the AFK app — the keyboard shows an orange mic (session.active
/// still true in the App Group) but tap/hold does nothing.
///
/// Important: the session must stay **mixable** (`.mixWithOthers`). Activating a
/// non-mixable session while backgrounded throws OSStatus 560557684 (`!int` =
/// `AVAudioSessionErrorCodeCannotInterruptOthers`). Pure digital silence is also
/// treated as "not playing" on some iOS builds — we emit a near-silent sine.
@MainActor
public final class SessionKeepalive {
    private var player: AVAudioPlayer?

    public init() {}

    public var isRunning: Bool { player?.isPlaying == true }

    /// Shared mixable category used by keepalive and capture so background
    /// reactivation never hits CannotInterruptOthers.
    public static func activateMixableSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker]
        )
        try session.setActive(true)
    }

    public func start() throws {
        if isRunning { return }
        try Self.activateMixableSession()

        let data = Self.nearSilentSineWav(sampleRate: 16_000, seconds: 1.0, frequency: 40, amplitude: 0.002)
        let player = try AVAudioPlayer(data: data)
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

    /// Stop playback but leave the AVAudioSession active (capture will own input).
    public func pauseForCapture() {
        player?.stop()
        player = nil
    }

    public func stop() {
        player?.stop()
        player = nil
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
