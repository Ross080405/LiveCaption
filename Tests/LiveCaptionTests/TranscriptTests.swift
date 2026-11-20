import XCTest
@testable import LiveCaption

final class TranscriptTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }

    func testSpeakerChangesSplitByWordAndKeepText() {
        let timeline = SpeakerTimeline(spans: [
            SpeakerSpan(start: at(0), end: at(1), label: "A"),
            SpeakerSpan(start: at(1), end: at(2), label: "B"),
            SpeakerSpan(start: at(2), end: at(3), label: "A")])
        let words = [CaptionWord(text: "Hello! ", start: at(0), end: at(0.9)),
                     CaptionWord(text: "你好。", start: at(1), end: at(1.9)),
                     CaptionWord(text: "Again.", start: at(2), end: at(2.9))]
        let lines = timeline.annotate([CaptionLine(text: "Hello! 你好。Again.", start: at(0), end: at(3), words: words)])
        XCTAssertEqual(lines.map(\.speaker), ["A", "B", "A"])
        XCTAssertEqual(lines.map(\.text), ["Hello!", "你好。", "Again."])
    }

    func testUnknownAndSimultaneousSpeakersAreNotInvented() {
        XCTAssertNil(SpeakerTimeline().label(start: at(0), end: at(1)))
        let timeline = SpeakerTimeline(spans: [SpeakerSpan(start: at(0), end: at(2), label: "A"), SpeakerSpan(start: at(0), end: at(2), label: "B")])
        XCTAssertEqual(timeline.label(start: at(0), end: at(1)), "A+B")
        XCTAssertNil(timeline.label(start: at(5), end: at(6)))
    }

    func testLongOverlappingIntervalAndUnsortedInput() {
        let timeline = SpeakerTimeline(spans: [SpeakerSpan(start: at(3), end: at(4), label: "B"),
                                               SpeakerSpan(start: at(0), end: at(10), label: "A")])
        XCTAssertEqual(timeline.label(start: at(7), end: at(8)), "A")
        XCTAssertEqual(timeline.label(start: at(3), end: at(4)), "A+B")
    }

    func testConsecutiveSpeakersAreNotReportedAsSimultaneous() {
        let timeline = SpeakerTimeline(spans: [SpeakerSpan(start: at(0), end: at(1), label: "A"),
                                               SpeakerSpan(start: at(1), end: at(2), label: "B")])
        XCTAssertNil(timeline.label(start: at(0), end: at(2)))
    }

    func testLateSpeakerResultReplacesUnknown() {
        let raw = [CaptionLine(text: "test", start: at(0), end: at(1))]
        XCTAssertEqual(SpeakerTimeline().annotate(raw).first?.speaker, "?")
        let timeline = SpeakerTimeline(spans: [SpeakerSpan(start: at(0), end: at(1), label: "C")])
        XCTAssertEqual(timeline.annotate(raw).first?.labeledText, "[C] test")
        XCTAssertNil(raw.first?.speaker)
    }

    func testExportRetainsLabelsUnicodeAndPartial() {
        let text = "# 会议\n\n[10:00:00] [A] 你好 👋\n[10:00:01] [B] Next …（识别中）\n"
        let snapshot = TranscriptSnapshot(name: "会议.md", markdown: text)
        XCTAssertEqual(snapshot.content(format: "md"), text)
        XCTAssertEqual(snapshot.content(format: "txt"), text.replacingOccurrences(of: "# 会议", with: "会议"))
        XCTAssertEqual(snapshot.filename(format: "txt"), "会议.txt")
    }

    func testFilePartialFinalizationAndContinuedPrefix() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = RecordingFile(folder: folder)
        file.beginNew(title: "test")
        let line = CaptionLine(text: "已完成", start: at(0), end: at(1), speaker: "A")
        let url = try XCTUnwrap(file.url)
        file.flush(lines: [line], partial: "[B] 正在说")
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[A] 已完成"))
        XCTAssertTrue(text.contains("[B] 正在说 …（识别中）"))
        file.end(lines: [line, CaptionLine(text: "说完了", start: at(1), end: at(2), speaker: "B")])
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("识别中"))
        XCTAssertEqual(try String(contentsOf: file.latestFile, encoding: .utf8), text)
        try file.beginContinuing(url)
        file.flush(lines: [CaptionLine(text: "追加", start: at(3), end: at(4), speaker: "A")])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix(text))
    }
}
