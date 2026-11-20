import XCTest
import AVFoundation
@testable import LiveCaption

final class SpeakerIntegrationTests: XCTestCase {
    /// Opt-in because this downloads a CoreML model. Uses synthetic voices, never live microphones.
    @MainActor func testStreamingVoicesAndPause() async throws {
        guard let folder = ProcessInfo.processInfo.environment["LIVE_CAPTION_SPEAKER_FIXTURES"] else {
            throw XCTSkip("Set LIVE_CAPTION_SPEAKER_FIXTURES to a folder containing 16 kHz mono a.wav and b.wav")
        }
        let diarizer = SpeakerDiarizer()
        var timeline = SpeakerTimeline()
        diarizer.onUpdate = { timeline = $0 }
        diarizer.onStatus = { print("Speaker model: \($0)") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            diarizer.prepare { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let base = Date()
        var elapsed: Double = 0
        var intervals: [(Date, Date)] = []
        for name in ["a.wav", "b.wav", "a.wav"] {
            if intervals.count == 2 { elapsed += 60 } // pause: no input; same voice must retain its label
            let start = base.addingTimeInterval(elapsed)
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: folder).appendingPathComponent(name))
            while file.framePosition < file.length {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000))
                try file.read(into: buffer)
                elapsed += Double(buffer.frameLength) / file.processingFormat.sampleRate
                diarizer.append(buffer, capturedAt: base.addingTimeInterval(elapsed))
                // A barrier every half-second prevents this faster-than-real-time fixture from overloading the input queue.
                // Use a small pacing delay; CoreML remains much faster than a live source on Apple Silicon.
                try await Task.sleep(nanoseconds: 120_000_000)
            }
            intervals.append((start, base.addingTimeInterval(elapsed)))
            await withCheckedContinuation { continuation in diarizer.drain { continuation.resume() } }
        }
        let labels = intervals.map { timeline.label(start: $0.0, end: $0.1) }
        print("Synthetic A/B/A dominant labels: \(labels)")
        XCTAssertNotNil(labels[0])
        XCTAssertNotNil(labels[1])
        XCTAssertNotEqual(labels[0], labels[1], "Different synthetic voices should not collapse into one speaker")
        XCTAssertEqual(labels[0], labels[2], "Pause/resume must retain speaker identity")
        XCTAssertFalse(timeline.spans.contains { $0.end.timeIntervalSince($0.start) > 50 }, "Pause must not become a speech span")
    }
}
