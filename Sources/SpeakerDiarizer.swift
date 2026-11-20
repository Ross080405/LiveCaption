import Foundation
import AVFoundation
import FluidAudio

/// One streaming model per recording. All inference and resampling runs on a serial queue.
/// Pauses drain right context using silence, preserving the model's speaker memory.
// Mutable state is confined to queue/main as noted, with the input backlog guarded by pendingLock.
final class SpeakerDiarizer: @unchecked Sendable {
    private struct ModelTransfer: @unchecked Sendable { let value: SortformerModels }
    var onUpdate: ((SpeakerTimeline) -> Void)?
    var onStatus: ((String) -> Void)?
    private let queue = DispatchQueue(label: "LiveCaption.speakers", qos: .userInitiated)
    private let model: SortformerDiarizer = {
        var config = DiarizerTimelineConfig.sortformerDefault
        config.maxStoredFrames = 750
        config.minFramesOn = 2
        config.minFramesOff = 2
        return SortformerDiarizer(config: .default, timelineConfig: config)
    }()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var samplesReceived = 0
    private struct Epoch { var offset: Double; var date: Date; var end: Double }
    private var epochs: [Epoch] = []
    private var needsEpoch = true
    private var labels: [Int: String] = [:]
    private var failed = false
    private let pendingLock = NSLock()
    private var pendingSeconds: Double = 0
    private var accepting = true
    private var preparing = false
    private var downloadPercent = -1
    private var waiters: [(Error?) -> Void] = []
    private(set) var ready = false // main thread only

    func prepare(completion: @escaping (Error?) -> Void) {
        if ready { completion(nil); return }
        waiters.append(completion)
        if preparing { return }
        preparing = true
        onStatus?("正在下载 / 加载说话人模型…")
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LiveCaption/speakers")
        Task { [self] in
            do {
                let models = try await SortformerModels.loadFromHuggingFace(config: .default, cacheDirectory: cache, progressHandler: { [self] progress in
                    DispatchQueue.main.async {
                        let percent = Int(progress.fractionCompleted * 100)
                        guard percent != self.downloadPercent else { return }
                        self.downloadPercent = percent
                        self.onStatus?("说话人模型：\(percent)%（首次需下载）")
                    }
                })
                let transfer = ModelTransfer(value: models)
                self.queue.async {
                    self.model.initialize(models: transfer.value)
                    DispatchQueue.main.async {
                        self.ready = true
                        self.onStatus?("实时分人已就绪 · 最多 4 人")
                        self.completePreparation(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.completePreparation(error) }
            }
        }
    }

    private func completePreparation(_ error: Error?) {
        preparing = false
        let callbacks = waiters
        waiters.removeAll()
        callbacks.forEach { $0(error) }
    }

    /// Called in the audio callback. Copy PCM memory before the capture system reuses it.
    func append(_ buffer: AVAudioPCMBuffer, capturedAt: Date = Date()) {
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let start = capturedAt.addingTimeInterval(-duration)
        pendingLock.lock()
        guard accepting else { pendingLock.unlock(); return }
        let overloaded = pendingSeconds > 8
        if overloaded { accepting = false } else { pendingSeconds += duration }
        pendingLock.unlock()
        if overloaded {
            queue.async { self.fail("说话人识别跟不上音频，已停止分人；文字识别继续。请结束后重试。") }
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            pendingLock.lock(); pendingSeconds -= duration; pendingLock.unlock()
            return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<source.count {
            if let src = source[i].mData, let dst = target[i].mData { memcpy(dst, src, Int(source[i].mDataByteSize)) }
        }
        queue.async {
            defer { self.pendingLock.lock(); self.pendingSeconds -= duration; self.pendingLock.unlock() }
            guard !self.failed else { return }
            do {
                if self.inputFormat != copy.format {
                    self.converter = AVAudioConverter(from: copy.format, to: self.outputFormat)
                    self.converter?.downmix = true
                    self.inputFormat = copy.format
                }
                guard let converter = self.converter,
                      let out = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: AVAudioFrameCount(duration * 16_000) + 64) else { return }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: out, error: &error) { _, state in
                    if supplied { state.pointee = .noDataNow; return nil }
                    supplied = true; state.pointee = .haveData; return copy
                }
                if let error { throw error }
                guard status != .error, let channel = out.floatChannelData?[0] else { return }
                if self.needsEpoch {
                    self.epochs.append(Epoch(offset: Double(self.samplesReceived) / 16_000, date: start, end: Double(self.samplesReceived) / 16_000))
                    self.needsEpoch = false
                }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
                self.samplesReceived += samples.count
                self.epochs[self.epochs.count - 1].end = Double(self.samplesReceived) / 16_000
                if try self.model.process(samples: samples) != nil { self.publish() }
            } catch { self.fail("说话人识别失败：\(error.localizedDescription)；文字识别继续。") }
        }
    }

    /// Barrier after audio capture stops; callbacks finish before the transcript is saved.
    func drain(completion: @escaping () -> Void) {
        queue.async {
            if !self.failed, !self.epochs.isEmpty {
                do {
                    let silence = [Float](repeating: 0, count: 24_000)
                    self.samplesReceived += silence.count
                    _ = try self.model.process(samples: silence)
                    self.publish()
                } catch { self.fail("说话人收尾失败：\(error.localizedDescription)") }
            }
            self.needsEpoch = true
            self.converter = nil
            self.inputFormat = nil
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        pendingLock.lock(); accepting = false; pendingLock.unlock()
        DispatchQueue.main.async { self.onStatus?(message) }
    }

    private func publish() {
        var segments: [DiarizerSegment] = []
        for speaker in model.timeline.speakers.values {
            segments.append(contentsOf: speaker.finalizedSegments)
            segments.append(contentsOf: speaker.tentativeSegments)
        }
        segments.sort { lhs, rhs in
            if lhs.startTime == rhs.startTime { return lhs.speakerIndex < rhs.speakerIndex }
            return lhs.startTime < rhs.startTime
        }
        var spans: [SpeakerSpan] = []
        for segment in segments {
            let start = Double(segment.startTime), end = Double(segment.endTime)
            for epoch in epochs {
                let lo = max(start, epoch.offset), hi = min(end, epoch.end)
                guard hi > lo else { continue }
                if labels[segment.speakerIndex] == nil {
                    labels[segment.speakerIndex] = String(UnicodeScalar(65 + labels.count)!)
                }
                spans.append(SpeakerSpan(start: epoch.date.addingTimeInterval(lo - epoch.offset),
                                         end: epoch.date.addingTimeInterval(hi - epoch.offset), label: labels[segment.speakerIndex]!))
            }
        }
        let timeline = SpeakerTimeline(spans: spans)
        DispatchQueue.main.async { self.onUpdate?(timeline) }
    }
}
