import Foundation

struct CaptionWord {
    var text: String
    var start: Date
    var end: Date
}

struct SpeakerSpan {
    var start: Date
    var end: Date
    var label: String
}

/// Align acoustic speaker turns with ASR timestamps, never with text meaning or sentence order.
struct SpeakerTimeline {
    let spans: [SpeakerSpan]
    private let prefixEnds: [Date]

    init(spans: [SpeakerSpan] = []) {
        self.spans = spans.sorted { $0.start < $1.start }
        var furthest = Date.distantPast
        self.prefixEnds = self.spans.map { span in
            furthest = max(furthest, span.end)
            return furthest
        }
    }

    func label(start: Date, end: Date) -> String? {
        let end = max(end, start.addingTimeInterval(0.08))
        var overlap: [String: TimeInterval] = [:]
        var candidates: [SpeakerSpan] = []
        // Interval lookup keeps long meetings from rescanning the entire timeline per word.
        var lo = 0, hi = spans.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if spans[mid].start < end { lo = mid + 1 } else { hi = mid }
        }
        var index = lo - 1
        while index >= 0 && prefixEnds[index] > start {
            let span = spans[index]
            if span.end > start {
                candidates.append(span)
                overlap[span.label, default: 0] += max(0, min(span.end, end).timeIntervalSince(max(span.start, start)))
            }
            index -= 1
        }
        let ranked = overlap.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let best = ranked.first, best.value >= min(0.08, end.timeIntervalSince(start) / 2) else { return nil }
        // Simultaneous speakers cannot be assigned individual words reliably.
        if ranked.count > 1, ranked[1].value >= best.value * 0.7 {
            let first = candidates.filter { $0.label == best.key }
            let second = candidates.filter { $0.label == ranked[1].key }
            let simultaneous = first.contains { a in
                second.contains { b in
                    min(end, min(a.end, b.end)).timeIntervalSince(max(start, max(a.start, b.start))) >= 0.04
                }
            }
            if simultaneous { return [best.key, ranked[1].key].sorted().joined(separator: "+") }
            // A long untimed phrase may cover consecutive speakers; that is not overlapping speech.
            if ranked[1].value >= best.value * 0.95 { return nil }
        }
        return best.key
    }

    func annotate(_ lines: [CaptionLine]) -> [CaptionLine] {
        lines.flatMap { line -> [CaptionLine] in
            guard !line.words.isEmpty else {
                var copy = line
                copy.speaker = label(start: line.start, end: line.end) ?? "?"
                return [copy]
            }
            var result: [CaptionLine] = []
            for word in line.words {
                let speaker = label(start: word.start, end: word.end) ?? "?"
                if result.last?.speaker == speaker {
                    result[result.count - 1].text += word.text
                    result[result.count - 1].end = word.end
                } else {
                    result.append(CaptionLine(text: word.text, start: word.start, end: word.end, speaker: speaker))
                }
            }
            return result.map { line in
                var copy = line
                copy.text = copy.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return copy
            }.filter { !$0.text.isEmpty }
        }
    }
}
