import Foundation
import AVFoundation
import WhisperKit

struct WhisperSettings {
    let model: String
    /// Whisper 语言代码（如 "en"、"zh"）；nil = 自动检测（适合多语言混说）
    let language: String?
    /// 普通话时把繁体结果转成简体
    let simplifiedChinese: Bool
}

/// 负责下载 / 加载 Whisper 模型（整个应用共用一份），并执行一次转写。
/// 所有对外方法都在主线程调用，回调也回到主线程。
final class WhisperEngine {
    static let shared = WhisperEngine()

    static let models: [(id: String, name: String)] = [
        ("large-v3-v20240930_turbo", "Large v3 Turbo（推荐：最准，速度快）"),
        ("large-v3-v20240930_626MB", "Large v3 Turbo 压缩版（626MB，省空间）"),
        ("small", "Small（较小较快，适合老电脑）"),
    ]
    static let defaultModel = "large-v3-v20240930_turbo"

    /// 模型下载位置：~/Library/Application Support/LiveCaption/whisper
    let downloadBase: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LiveCaption/whisper", isDirectory: true)
    }()

    private(set) var loadedModel: String?
    private var pipe: WhisperKit?
    private var loadingModel: String?
    private var waiters: [(String?) -> Void] = []
    private var statusHandler: ((String) -> Void)?
    private let defaults = UserDefaults.standard

    var isLoaded: Bool { pipe != nil }

    // MARK: - 下载 / 加载

    /// 确保模型可用。completion(nil) 表示就绪，否则是错误描述。
    func prepare(model: String, status: @escaping (String) -> Void, completion: @escaping (String?) -> Void) {
        if loadedModel == model, pipe != nil {
            completion(nil)
            return
        }
        statusHandler = status
        waiters.append(completion)
        if loadingModel != nil { return }   // 正在加载，等它完成

        loadingModel = model
        pipe = nil
        loadedModel = nil

        let savedKey = "whisperFolder.\(model)"
        let savedPath = defaults.string(forKey: savedKey)
        let base = downloadBase

        Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let folder: URL
                if let savedPath, Self.looksLikeModelFolder(savedPath) {
                    folder = URL(fileURLWithPath: savedPath)
                } else {
                    self?.report("正在下载 Whisper 模型…（只需下载一次）")
                    folder = try await WhisperKit.download(variant: model, downloadBase: base, progressCallback: { progress in
                        let percent = Int(progress.fractionCompleted * 100)
                        self?.report("正在下载 Whisper 模型 \(percent)%（只需下载一次）")
                    })
                    DispatchQueue.main.async { self?.defaults.set(folder.path, forKey: savedKey) }
                }

                self?.report("正在加载 Whisper 模型…第一次会比较久（系统在为你的芯片优化模型）")
                let config = WhisperKitConfig(downloadBase: base,
                                              modelFolder: folder.path,
                                              verbose: false,
                                              prewarm: true,
                                              load: true,
                                              download: false)
                let kit = try await WhisperKit(config)
                DispatchQueue.main.async {
                    self?.pipe = kit
                    self?.loadedModel = model
                    self?.finishLoading(nil)
                }
            } catch {
                let message = "Whisper 模型准备失败：\(error.localizedDescription)\n第一次使用需要联网下载模型；也可以在「识别引擎」里切回系统识别。"
                DispatchQueue.main.async { self?.finishLoading(message) }
            }
        }
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.statusHandler?(text) }
    }

    private func finishLoading(_ error: String?) {
        loadingModel = nil
        statusHandler = nil
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0(error) }
    }

    private static func looksLikeModelFolder(_ path: String) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return items.contains { $0.hasPrefix("AudioEncoder") } && items.contains { $0.hasPrefix("TextDecoder") }
    }

    // MARK: - 转写

    /// 转写一段 16kHz 单声道音频。completion 在主线程回调，失败时为 nil。
    func transcribe(_ audio: [Float], settings: WhisperSettings, completion: @escaping (String?) -> Void) {
        guard let pipe else { completion(nil); return }
        let options = DecodingOptions(
            task: .transcribe,
            language: settings.language,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: settings.language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true
        )
        Task {
            let results = try? await pipe.transcribe(audioArray: audio, decodeOptions: options)
            let raw = results?.map(\.text).joined(separator: " ")
            let text = raw.map { Self.clean($0, simplified: settings.simplifiedChinese) }
            DispatchQueue.main.async { completion(text) }
        }
    }

    /// 去掉特殊标记和 Whisper 在静音时常见的「幻听」句子
    private static func clean(_ text: String, simplified: Bool) -> String {
        var t = text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 整句都是 [音乐] / (applause) 之类的标注
        if t.range(of: "^[\\[\\(（【].*[\\]\\)）】]$", options: .regularExpression) != nil { return "" }
        let lower = t.lowercased()
        let hallucinations = [
            "thank you.", "thank you", "thanks for watching!", "thanks for watching.", "thank you for watching.",
            "thank you for watching!", "bye.", "you", "please subscribe.", "谢谢观看", "谢谢大家", "謝謝觀看",
        ]
        if hallucinations.contains(lower) { return "" }
        let markers = ["amara.org", "字幕由", "字幕志愿者", "请不吝点赞", "订阅我的频道", "訂閱", "明镜与点点"]
        if markers.contains(where: { lower.contains($0) }) { return "" }
        if simplified {
            t = (t as NSString).applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? t
        }
        return t
    }
}

/// 把连续的音频流切成「一句一句」交给 Whisper：
/// - 说话过程中每 ~0.5 秒把当前这句重新识别一次 → 实时显示（partial）
/// - 检测到停顿 ~0.8 秒（或一句超过 25 秒）→ 最终识别这一句并定稿（commit）
final class WhisperStreamer {
    var onPartial: ((String) -> Void)?
    var onCommit: ((String, Date, Date) -> Void)?

    private let settings: WhisperSettings
    private let engine = WhisperEngine.shared
    private static let sampleRate = 16_000.0

    // —— 以下由音频线程和主线程共享，用 lock 保护 ——
    private let lock = NSLock()
    private var samples: [Float] = []          // 当前这句的音频（16kHz）
    private var samplesStart = Date()          // samples[0] 对应的时间
    private var lastSpeechIndex = 0            // 最后一次检测到说话的位置
    private var hasSpeech = false
    private var noiseFloor: Float = 0
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                             channels: 1, interleaved: false)!

    // —— 以下只在主线程使用 ——
    private var timer: Timer?
    private var busy = false
    private var lastPartialLength = 0
    private var finishing = false
    private var finishCompletion: (() -> Void)?

    init(settings: WhisperSettings) {
        self.settings = settings
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// 停止：把最后一句识别完、定稿后再调用 completion
    func finish(completion: @escaping () -> Void) {
        timer?.invalidate()
        timer = nil
        finishing = true
        finishCompletion = completion
        tryFinish()
    }

    // MARK: - 音频线程

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let converted = convert(buffer) else { return }

        // 简单的能量检测（VAD）：自适应噪声底
        var sum: Float = 0
        for s in converted { sum += s * s }
        let rms = converted.isEmpty ? 0 : (sum / Float(converted.count)).squareRoot()
        if noiseFloor == 0 {
            noiseFloor = rms
        } else if rms < noiseFloor {
            noiseFloor = noiseFloor * 0.9 + rms * 0.1
        } else {
            noiseFloor = noiseFloor * 0.998 + rms * 0.002
        }
        let isSpeech = rms > max(0.008, noiseFloor * 2.5)

        samples.append(contentsOf: converted)
        if isSpeech {
            hasSpeech = true
            lastSpeechIndex = samples.count
        } else if !hasSpeech && samples.count > 8_000 {
            // 还没开口：只保留最近 0.5 秒作为前导
            let drop = samples.count - 8_000
            samples.removeFirst(drop)
            samplesStart = samplesStart.addingTimeInterval(Double(drop) / Self.sampleRate)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true   // 多声道混成单声道
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var provided = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if provided {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
    }

    // MARK: - 主线程

    private func tick() {
        guard !busy, !finishing else { return }

        lock.lock()
        let snapshot = samples
        let speechEnd = lastSpeechIndex
        let speaking = hasSpeech
        let start = samplesStart
        lock.unlock()

        guard speaking else { return }
        let silence = Double(snapshot.count - speechEnd) / Self.sampleRate
        let duration = Double(snapshot.count) / Self.sampleRate

        if silence >= 0.8 || duration >= 25 {
            // 一句结束：截到说话结束后 0.3 秒，最终识别并定稿
            let cut = min(snapshot.count, speechEnd + 4_800)
            let audio = Array(snapshot[0..<cut])
            consume(cut)
            commit(audio, start: start)
        } else if snapshot.count - lastPartialLength >= 8_000 {
            // 每多 0.5 秒新音频，就刷新一次实时字幕
            lastPartialLength = snapshot.count
            busy = true
            engine.transcribe(snapshot, settings: settings) { [weak self] text in
                guard let self else { return }
                self.busy = false
                if !self.finishing, let text { self.onPartial?(text) }
                if self.finishing { self.tryFinish() }
            }
        }
    }

    /// 从缓冲区里移除已经交出去的音频
    private func consume(_ count: Int) {
        lock.lock()
        let n = min(count, samples.count)
        samples.removeFirst(n)
        samplesStart = samplesStart.addingTimeInterval(Double(n) / Self.sampleRate)
        lastSpeechIndex = max(0, lastSpeechIndex - n)
        hasSpeech = lastSpeechIndex > 0
        lock.unlock()
        lastPartialLength = 0
    }

    private func commit(_ audio: [Float], start: Date, then: (() -> Void)? = nil) {
        guard audio.count >= 4_800 else {   // 不到 0.3 秒，忽略
            onPartial?("")
            then?()
            return
        }
        let end = start.addingTimeInterval(Double(audio.count) / Self.sampleRate)
        busy = true
        engine.transcribe(audio, settings: settings) { [weak self] text in
            guard let self else { return }
            self.busy = false
            if let text, !text.isEmpty {
                self.onCommit?(text, start, end)
            } else {
                self.onPartial?("")
            }
            if let then { then() } else if self.finishing { self.tryFinish() }
        }
    }

    private func tryFinish() {
        guard finishing, !busy, let completion = finishCompletion else { return }
        finishCompletion = nil

        lock.lock()
        let snapshot = samples
        let speaking = hasSpeech
        let start = samplesStart
        samples.removeAll()
        hasSpeech = false
        lastSpeechIndex = 0
        lock.unlock()

        if speaking {
            commit(snapshot, start: start, then: completion)
        } else {
            onPartial?("")
            completion()
        }
    }
}
