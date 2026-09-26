import Foundation

public enum PCMWav {
    public static let defaultSampleRate = 16_000

    public static func wav(pcm16 pcm: Data, sampleRate: Int = defaultSampleRate) -> Data {
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var out = Data()
        out.append(contentsOf: "RIFF".utf8)
        out.append(le32(36 + pcm.count))
        out.append(contentsOf: "WAVEfmt ".utf8)
        out.append(le32(16))
        out.append(le16(1)) // PCM
        out.append(le16(1)) // mono
        out.append(le32(sampleRate))
        out.append(le32(sampleRate * 2))
        out.append(le16(2))
        out.append(le16(16))
        out.append(contentsOf: "data".utf8)
        out.append(le32(pcm.count))
        out.append(pcm)
        return out
    }
}
