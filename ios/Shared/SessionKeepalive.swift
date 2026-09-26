import AVFoundation
import Foundation

/// Keeps `UIBackgroundModes: audio` honest while a dictation session is active.
///
/// Activating `AVAudioSession` alone does **not** prevent suspension. iOS only
/// keeps the process running when audio is actually playing or recording.
/// Without this, Darwin notifies and the command poll timer never fire once the
/// user leaves the AFK app — the keyboard shows an orange mic (session.active
/// still true in the App Group) but tap/hold does nothing.
@MainActor
public final class SessionKeepalive {
    private var player: AVAudioPlayer?

    public init() {}

    public var isRunning: Bool { player?.isPlaying == true }

    public func start() throws {
        if isRunning { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
        try session.setActive(true)

        let data = Self.silentWav(sampleRate: 8_000, seconds: 1.0)
        let player = try AVAudioPlayer(data: data)
        // Volume 0 is ignored by the background audio assertion on some iOS builds.
        player.volume = 0.01
        player.numberOfLoops = -1
        player.prepareToPlay()
        guard player.play() else {
            throw AudioCapture.CaptureError.engineStart("Silent keepalive failed to play")
        }
        self.player = player
    }

    public func stop() {
        player?.stop()
        player = nil
    }

    /// Minimal PCM16 mono WAV of silence.
    private static func silentWav(sampleRate: Int, seconds: Double) -> Data {
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
        data.append(Data(count: dataSize))
        return data
    }
}
