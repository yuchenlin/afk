import AVFoundation
import XCTest
@testable import AFKCore

/// Mirrors how AppDelegate uses a session: it drops its reference right after `finish`.
final class GrokSessionLifetimeTests: XCTestCase {
    /// Regression: the session used to be freed after `finish`, so no result ever arrived
    /// and the overlay stayed on "Transcribing…".
    func testDeliversResultAfterCallerDropsReference() {
        var config = GrokSttConfig(apiKey: "test")
        config.host = "127.0.0.1:9"  // nothing listens: stream fails, batch fails
        let done = expectation(description: "completion delivered")

        weak var weakSession: GrokSttSession?
        do {
            let session = GrokSttSession(config: config)
            weakSession = session
            session.start()
            session.append(Data(count: 32_000))  // 1 s of silence
            session.finish(timeout: 1) { result in
                if case .success = result { XCTFail("expected a connection failure") }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 15)

        let released = expectation(description: "session released after completion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            XCTAssertNil(weakSession, "session should not leak once the result is delivered")
            released.fulfill()
        }
        wait(for: [released], timeout: 2)
    }

    func testCancelDeliversNothing() {
        var config = GrokSttConfig(apiKey: "test")
        config.host = "127.0.0.1:9"
        let session = GrokSttSession(config: config)
        session.start()
        session.append(Data(count: 32_000))
        session.cancel()
        let noResult = expectation(description: "no completion after cancel")
        noResult.isInverted = true
        session.finish(timeout: 0.2) { _ in noResult.fulfill() }
        wait(for: [noResult], timeout: 1)
    }

    /// Live round trip through the real API, streamed in 100 ms chunks like the mic.
    /// Runs only when XAI_API_KEY_VOICE is set.
    func testLiveStreamingRoundTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["XAI_API_KEY_VOICE"], !key.isEmpty else {
            throw XCTSkip("no xAI API key in the environment")
        }
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("afk-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", wav.path, "--data-format=LEI16@16000", "Testing the AFK dictation pipeline with CUDA."]
        try say.run()
        say.waitUntilExit()
        let pcm = try Data(contentsOf: wav).dropFirst(44)

        let done = expectation(description: "live transcript")
        var transcript = ""
        do {
            let session = GrokSttSession(config: GrokSttConfig(apiKey: key, keyterms: ["CUDA", "AFK"]))
            session.start()
            var offset = pcm.startIndex
            while offset < pcm.endIndex {
                let end = min(offset + 3200, pcm.endIndex)
                session.append(Data(pcm[offset..<end]))
                offset = end
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            session.finish { result in
                transcript = (try? result.get()) ?? "error: \(result)"
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 30)
        XCTAssertTrue(transcript.localizedCaseInsensitiveContains("pipeline"), transcript)
        XCTAssertTrue(transcript.contains("CUDA"), transcript)
    }

    func testMicConversionTo16kPCM() throws {
        let source = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        converter.downmix = true

        var bytes = 0
        for _ in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 4800))
            buffer.frameLength = 4800  // 100 ms
            for ch in 0..<2 {
                for i in 0..<4800 { buffer.floatChannelData![ch][i] = 0.3 * sin(Float(i) * 0.05) }
            }
            bytes += AudioRecorder.convert(buffer, with: converter, to: target)?.count ?? 0
        }
        // 1 s of 16 kHz mono PCM16 = 32,000 bytes; allow converter latency.
        XCTAssertGreaterThan(bytes, 30_000)
        XCTAssertLessThanOrEqual(bytes, 32_000)
    }
}
