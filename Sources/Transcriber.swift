import Foundation
import Speech
import AVFoundation

/// 识别引擎：系统自带（快、省电）或 Whisper（更准，适合口音、中英混说）
enum RecognitionEngine: String {
    case apple
    case whisper
}

enum AudioSourceKind: String {
    case microphone
    case systemAudio
}

struct CaptionLine {
    var text: String
    let start: Date
    var end: Date
    var speaker: String? = nil
    var words: [CaptionWord] = []
    var labeledText: String { speaker.map { "[\($0)] \(text)" } ?? text }
}

struct TranscriberError {
    let message: String
    /// 对应「系统设置 → 隐私与安全性」中的页面锚点，用于一键跳转
    let settingsAnchor: String?
}

/// 负责：采集音频（麦克风 / 系统声音）→ 喂给 SFSpeechRecognizer → 产出字幕行。
///
/// 识别按「段」进行：说话停顿 ~1.2 秒、或一段超过 50 秒，就把当前文字定稿成一行，
/// 并立刻开启新的一段识别。旧的那段在后台收尾，拿到最终结果后再回填修正那一行。
/// 这样既能自然断句，也能绕开系统对单次识别时长的限制。
/// 除音频回调外，所有方法都在主线程调用。
final class Transcriber: NSObject {
    var onChange: (() -> Void)?
    var onStateChange: ((Bool) -> Void)?
    var onFatalError: ((TranscriberError) -> Void)?

    private var annotatedLines: [CaptionLine]?
    private var rawLines: [CaptionLine] = [] { didSet { annotatedLines = nil } }
    private var timeline = SpeakerTimeline() { didSet { annotatedLines = nil } }
    private var speakerDiarizer: SpeakerDiarizer?
    private var speakerEnabled = false
    private(set) var speakerStatus = ""
    private var partialWords: [CaptionWord] = []
    var lines: [CaptionLine] {
        guard speakerEnabled else { return rawLines }
        if let annotatedLines { return annotatedLines }
        let result = timeline.annotate(rawLines)
        annotatedLines = result
        return result
    }
    var partialSpeaker: String? {
        guard speakerEnabled, !partial.isEmpty else { return nil }
        if let word = partialWords.last { return timeline.label(start: word.start, end: word.end) ?? "?" }
        return timeline.label(start: partialStart ?? Date().addingTimeInterval(-1), end: Date()) ?? "?"
    }
    var labeledPartial: String { partialSpeaker.map { "[\($0)] \(partial)" } ?? partial }
    private var activeDiarizer: SpeakerDiarizer? // guarded by requestLock

    private(set) var partial = ""
    private(set) var isRunning = false
    private(set) var origin: Date?          // 本次记录的起点（用于导出 SRT 时间轴）
    private(set) var isOnDevice = false
    private(set) var isStarting = false
    /// Whisper 停止后还在识别最后一句
    private(set) var isFinishing = false
    /// 正在下载 / 加载模型等提示（显示在字幕条上）
    private(set) var statusMessage: String?
    private(set) var recognitionEngine: RecognitionEngine = .apple
    private var startToken = 0
    private var whisperStreamer: WhisperStreamer?

    var silenceCommitInterval: TimeInterval = 1.2
    var maxSegmentDuration: TimeInterval = 50

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var sessionID = 0
    private var sessionStart = Date()
    private var partialStart: Date?
    private var lastPartialChange = Date()
    private var tickTimer: Timer?
    private var finishing: [Int: (lineIndex: Int, task: SFSpeechRecognitionTask, start: Date)] = [:]
    private var consecutiveErrors = 0

    // 音频线程会读取当前请求，用锁保护
    private let requestLock = NSLock()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var activeStreamer: WhisperStreamer?

    private let engine = AVAudioEngine()
    private var micTapInstalled = false
    private var configObserver: NSObjectProtocol?
    private var systemCapture: SystemAudioCapture?
    private var source: AudioSourceKind = .microphone

    // 诊断：音频统计（音频线程写、主线程读，用 statsLock 保护）
    private let statsLock = NSLock()
    private var statChunks = 0
    private var statRmsSum: Float = 0
    private var statPeak: Float = 0
    private var lastRms: Float = 0
    private var lastBufferTime = Date.distantPast
    private var statsTimer: Timer?
    private var loggedBufferFormat = false

    /// 本地识别一直失败时改走在线识别
    private var forceOnline = false
    private var onDeviceGotResult = false
    private var onDeviceFailures = 0

    /// 当前输入音量 0…1（约 -60dB…-10dB），最近 0.4 秒没收到音频则为 0。任何线程可读。
    var inputLevel: Float {
        statsLock.lock()
        let rms = lastRms
        let age = Date().timeIntervalSince(lastBufferTime)
        statsLock.unlock()
        guard age < 0.4, rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return max(0, min(1, (db + 60) / 50))
    }

    /// 最近 0.4 秒内有没有音频数据送达（哪怕是静音）
    var isReceivingAudio: Bool {
        statsLock.lock()
        defer { statsLock.unlock() }
        return Date().timeIntervalSince(lastBufferTime) < 0.4
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func startStatsTimer() {
        statsLock.lock()
        statChunks = 0; statRmsSum = 0; statPeak = 0
        statsLock.unlock()
        statsTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.logAudioStats() }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer
    }

    private func logAudioStats() {
        statsLock.lock()
        let chunks = statChunks
        let avg = chunks > 0 ? statRmsSum / Float(chunks) : 0
        let peak = statPeak
        statChunks = 0; statRmsSum = 0; statPeak = 0
        statsLock.unlock()
        if chunks == 0 {
            Log.write("音频统计(5s)：没有收到任何音频块 ⚠️（来源=\(source.rawValue)）")
        } else {
            let db = avg > 0 ? String(format: "%.1f", 20 * log10(avg)) : "-inf"
            Log.write(String(format: "音频统计(5s)：%d 块，平均音量 rms=%.5f (%@ dB)，峰值 rms=%.5f%@",
                             chunks, avg, db, peak, peak < 0.0005 ? " ⚠️ 全是静音" : ""))
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let p = data[0]
            for i in 0..<n { sum += p[i] * p[i] }
        } else if let data = buffer.int16ChannelData {
            let p = data[0]
            for i in 0..<n { let v = Float(p[i]) / 32768; sum += v * v }
        } else if let data = buffer.int32ChannelData {
            let p = data[0]
            for i in 0..<n { let v = Float(p[i]) / 2_147_483_648; sum += v * v }
        } else {
            return 0
        }
        return (sum / Float(n)).squareRoot()
    }

    // MARK: - 开始 / 停止

    func start(localeID: String, source: AudioSourceKind,
               engine: RecognitionEngine = .apple, whisper: WhisperSettings? = nil, speakers: Bool = true) {
        guard !isRunning, !isStarting, !isFinishing else { return }
        speakerEnabled = speakers
        if speakers && speakerDiarizer?.ready != true {
            isStarting = true
            startToken += 1
            let token = startToken
            let diarizer = speakerDiarizer ?? SpeakerDiarizer()
            speakerDiarizer = diarizer
            diarizer.onStatus = { [weak self, weak diarizer] status in
                guard let self, self.speakerDiarizer === diarizer else { return }
                self.speakerStatus = status
                if self.isStarting { self.statusMessage = status }
                self.onChange?()
            }
            diarizer.onUpdate = { [weak self, weak diarizer] timeline in
                guard let self, self.speakerDiarizer === diarizer else { return }
                self.timeline = timeline
                self.onChange?()
            }
            diarizer.prepare { [weak self] error in
                guard let self, token == self.startToken else { return }
                self.isStarting = false
                self.statusMessage = nil
                if let error {
                    self.speakerStatus = "模型加载失败，可关闭实时分人后继续录音"
                    self.onFatalError?(TranscriberError(message: "说话人模型加载失败：\(error.localizedDescription)\n可在设置关闭实时分人，或联网后重试。", settingsAnchor: nil))
                    self.onChange?()
                    return
                }
                self.start(localeID: localeID, source: source, engine: engine, whisper: whisper, speakers: speakers)
            }
            return
        }
        isStarting = true
        startToken += 1
        let token = startToken
        self.source = source
        let useWhisper = engine == .whisper && whisper != nil

        Log.write("开始：引擎=\(useWhisper ? "whisper(\(whisper?.model ?? ""), 语言=\(whisper?.language ?? "auto"))" : "apple") 语言=\(localeID) 来源=\(source.rawValue)")
        Log.write("权限（请求前）：语音识别=\(Self.describe(SFSpeechRecognizer.authorizationStatus())) 麦克风=\(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)))")

        requestPermissions(for: source, needsSpeechRecognition: !useWhisper) { [weak self] error in
            guard let self, token == self.startToken else { return }
            Log.write("权限（请求后）：语音识别=\(Self.describe(SFSpeechRecognizer.authorizationStatus())) 麦克风=\(Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)))\(error.map { " → 失败：\($0.message)" } ?? "")")
            if let error {
                self.isStarting = false
                self.onFatalError?(error)
                return
            }

            if useWhisper, let whisper {
                // 先确保模型已下载、已加载（第一次可能要几分钟）
                WhisperEngine.shared.prepare(model: whisper.model, status: { [weak self] message in
                    guard let self, token == self.startToken else { return }
                    self.statusMessage = message
                    self.onChange?()
                }) { [weak self] error in
                    guard let self, token == self.startToken else { return }
                    self.isStarting = false
                    self.statusMessage = nil
                    if let error {
                        self.onChange?()
                        self.onFatalError?(TranscriberError(message: error, settingsAnchor: nil))
                        return
                    }
                    self.beginWhisper(whisper)
                }
                return
            }

            self.isStarting = false
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
                Log.write("SFSpeechRecognizer(locale: \(localeID)) 创建失败：不支持该语言")
                self.onFatalError?(TranscriberError(message: "系统不支持该识别语言：\(localeID)", settingsAnchor: nil))
                return
            }
            Log.write("识别器：locale=\(recognizer.locale.identifier) isAvailable=\(recognizer.isAvailable) supportsOnDeviceRecognition=\(recognizer.supportsOnDeviceRecognition)")
            guard recognizer.isAvailable else {
                self.onFatalError?(TranscriberError(
                    message: "语音识别暂时不可用。\n请确认已联网，或在「系统设置 → 键盘 → 听写」中开启听写后重试。",
                    settingsAnchor: nil))
                return
            }
            self.recognitionEngine = .apple
            self.recognizer = recognizer
            self.isOnDevice = recognizer.supportsOnDeviceRecognition && !self.forceOnline
            self.isRunning = true
            self.consecutiveErrors = 0
            self.onDeviceFailures = 0
            if self.origin == nil { self.origin = Date() }
            self.startNewSegment()
            self.startAudioOrFail()
            self.startStatsTimer()

            self.tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.tick()
            }
            self.onStateChange?(true)
            self.onChange?()
        }
    }

    private func beginWhisper(_ settings: WhisperSettings) {
        recognitionEngine = .whisper
        isOnDevice = true
        isRunning = true
        if origin == nil { origin = Date() }

        let streamer = WhisperStreamer(settings: settings)
        streamer.onPartial = { [weak self] text, words in
            guard let self else { return }
            if self.partial.isEmpty && !text.isEmpty { self.partialStart = Date() }
            self.partial = text
            self.partialWords = words
            self.onChange?()
        }
        streamer.onCommit = { [weak self] text, start, end, words in
            guard let self else { return }
            Log.write("定稿[whisper] #\(self.lines.count + 1)：\(text)")
            self.rawLines.append(CaptionLine(text: text, start: start, end: end, words: words))
            self.partial = ""
            self.partialStart = nil
            self.onChange?()
        }
        whisperStreamer = streamer
        requestLock.lock()
        activeStreamer = streamer
        requestLock.unlock()
        streamer.start()

        startAudioOrFail()
        startStatsTimer()
        onStateChange?(true)
        onChange?()
    }

    private func startAudioOrFail() {
        requestLock.lock()
        activeDiarizer = speakerEnabled ? speakerDiarizer : nil
        requestLock.unlock()
        startAudio { [weak self] error in
            guard let self else { return }
            if let error {
                Log.write("音频启动失败：\(error.message)")
                self.stop()
                self.onFatalError?(error)
            }
        }
    }

    /// 停止识别。completion 在所有文字都定稿后调用（Whisper 需要再识别完最后一句）。
    func stop(completion: (() -> Void)? = nil) {
        if isFinishing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.stop(completion: completion) }
            return
        }
        stopRecognition { [weak self] in
            guard let self else { completion?(); return }
            self.requestLock.lock()
            let diarizer = self.activeDiarizer
            self.activeDiarizer = nil
            self.requestLock.unlock()
            guard let diarizer else { completion?(); return }
            self.isFinishing = true
            self.onChange?()
            diarizer.drain { [weak self] in
                self?.isFinishing = false
                self?.onChange?()
                completion?()
            }
        }
    }

    private func stopRecognition(completion: (() -> Void)? = nil) {
        if isStarting {
            // 还在请求权限或加载模型：取消这次开始
            startToken += 1
            isStarting = false
            statusMessage = nil
            onChange?()
            completion?()
            return
        }
        guard isRunning else { completion?(); return }
        isRunning = false
        tickTimer?.invalidate()
        tickTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        Log.write("停止：共 \(lines.count) 句")
        stopMic()
        systemCapture?.stop()
        systemCapture = nil

        if let streamer = whisperStreamer {
            requestLock.lock()
            activeStreamer = nil
            requestLock.unlock()
            whisperStreamer = nil
            isFinishing = true
            onStateChange?(false)
            onChange?()
            var finished = false
            let finish: (String?) -> Void = { [weak self] problem in
                guard !finished else { return }
                finished = true
                if let problem { Log.write(problem) }
                guard let self else { return }
                self.isFinishing = false
                self.partial = ""
                self.onChange?()
                completion?()
            }
            streamer.finish { finish(nil) }
            // 保险：最后一句迟迟识别不完也不能让界面一直卡在「正在收尾」
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish("停止：等最后一句识别超过 20 秒，放弃等待") }
            return
        }

        finishSegment()
        isFinishing = true
        onStateChange?(false)
        onChange?()
        finishAppleStop(deadline: Date().addingTimeInterval(5.1), completion: completion)
    }

    private func finishAppleStop(deadline: Date, completion: (() -> Void)?) {
        if finishing.isEmpty || Date() >= deadline {
            for entry in finishing.values { entry.task.cancel() }
            finishing.removeAll()
            isFinishing = false
            onChange?()
            completion?()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.finishAppleStop(deadline: deadline, completion: completion)
            }
        }
    }

    func clear() {
        for entry in finishing.values { entry.task.cancel() }
        finishing.removeAll()
        rawLines.removeAll()
        timeline = SpeakerTimeline()
        speakerDiarizer = nil
        speakerStatus = ""
        partialWords = []
        origin = isRunning ? Date() : nil
        onChange?()
    }

    // MARK: - 权限

    private func requestPermissions(for source: AudioSourceKind, needsSpeechRecognition: Bool,
                                    completion: @escaping (TranscriberError?) -> Void) {
        let askSpeech: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = { handler in
            if needsSpeechRecognition {
                SFSpeechRecognizer.requestAuthorization(handler)
            } else {
                handler(.authorized)   // Whisper 在本地运行，不需要系统「语音识别」权限
            }
        }
        askSpeech { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    completion(TranscriberError(
                        message: "没有「语音识别」权限。\n请在「系统设置 → 隐私与安全性 → 语音识别」中允许 LiveCaption。",
                        settingsAnchor: "Privacy_SpeechRecognition"))
                    return
                }
                guard source == .microphone else { completion(nil); return }

                let micDenied = TranscriberError(
                    message: "没有「麦克风」权限。\n请在「系统设置 → 隐私与安全性 → 麦克风」中允许 LiveCaption。",
                    settingsAnchor: "Privacy_Microphone")
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized:
                    completion(nil)
                case .notDetermined:
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        DispatchQueue.main.async { completion(granted ? nil : micDenied) }
                    }
                default:
                    completion(micDenied)
                }
            }
        }
    }

    // MARK: - 音频采集

    private func startAudio(completion: @escaping (TranscriberError?) -> Void) {
        // 调试用：--args -testAudioFile /path/to.wav  用音频文件代替麦克风（按实时速度送入）
        if let path = UserDefaults.standard.string(forKey: "testAudioFile") {
            startTestFile(path, completion: completion)
            return
        }
        switch source {
        case .microphone:
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            Log.write("麦克风：设备=\(AVCaptureDevice.default(for: .audio)?.localizedName ?? "无") 输入格式=\(format.sampleRate)Hz \(format.channelCount)声道 \(format.commonFormat == .pcmFormatFloat32 ? "float32" : "format#\(format.commonFormat.rawValue)") interleaved=\(format.isInterleaved)")
            guard format.sampleRate > 0, format.channelCount > 0 else {
                completion(TranscriberError(message: "没有找到可用的麦克风。", settingsAnchor: nil))
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.append(buffer)
            }
            micTapInstalled = true
            engine.prepare()
            do {
                try engine.start()
            } catch {
                completion(TranscriberError(message: "麦克风启动失败：\(error.localizedDescription)", settingsAnchor: nil))
                return
            }
            // 插拔耳机 / 切换输入设备时，重新挂接麦克风
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in
                self?.restartMic()
            }
            completion(nil)

        case .systemAudio:
            let capture = SystemAudioCapture()
            capture.onBuffer = { [weak self] buffer in self?.append(buffer) }
            capture.onError = { [weak self, weak capture] message in
                DispatchQueue.main.async {
                    guard let self, self.isRunning, let capture, self.systemCapture === capture else { return }
                    self.stop()
                    self.onFatalError?(TranscriberError(message: message, settingsAnchor: nil))
                }
            }
            systemCapture = capture
            capture.start { message in
                Log.write("系统声音采集：\(message ?? "已启动")")
                DispatchQueue.main.async {
                    completion(message.map { TranscriberError(message: $0, settingsAnchor: "Privacy_ScreenCapture") })
                }
            }
        }
    }

    private var testFeedToken = 0

    private func startTestFile(_ path: String, completion: @escaping (TranscriberError?) -> Void) {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
            completion(TranscriberError(message: "测试音频打不开：\(path)", settingsAnchor: nil))
            return
        }
        let format = file.processingFormat
        Log.write("测试音频：\(path) \(format.sampleRate)Hz \(format.channelCount)声道 \(Double(file.length) / format.sampleRate)s")
        testFeedToken += 1
        let token = testFeedToken
        let chunk = AVAudioFrameCount(format.sampleRate / 10)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var next = Date()
            var ended = false
            while let self, self.testFeedToken == token {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
                if !ended {
                    try? file.read(into: buffer, frameCount: chunk)
                    if buffer.frameLength == 0 {
                        ended = true
                        Log.write("测试音频：播放完毕，之后送静音")
                    }
                }
                if ended {   // 文件结束后继续送静音，让最后一句能定稿
                    buffer.frameLength = chunk
                    for c in 0..<Int(format.channelCount) {
                        memset(buffer.floatChannelData?[c], 0, Int(chunk) * MemoryLayout<Float>.size)
                    }
                }
                self.append(buffer)
                next = next.addingTimeInterval(0.1)
                Thread.sleep(until: next)
            }
        }
        completion(nil)
    }

    private func stopMic() {
        testFeedToken += 1
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
        if engine.isRunning { engine.stop() }
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
    }

    private func restartMic() {
        guard isRunning, source == .microphone else { return }
        stopMic()
        startAudio { [weak self] error in
            guard let self, let error else { return }
            self.stop()
            self.onFatalError?(error)
        }
    }

    /// 在音频线程调用
    private func append(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(of: buffer)
        statsLock.lock()
        statChunks += 1
        statRmsSum += rms
        statPeak = max(statPeak, rms)
        lastRms = rms
        lastBufferTime = Date()
        let first = !loggedBufferFormat
        loggedBufferFormat = true
        statsLock.unlock()
        if first {
            Log.write("收到第一块音频：\(buffer.format.sampleRate)Hz \(buffer.format.channelCount)声道 \(buffer.frameLength) 帧")
        }

        requestLock.lock()
        let request = currentRequest
        let streamer = activeStreamer
        let diarizer = activeDiarizer
        requestLock.unlock()
        request?.append(buffer)
        streamer?.append(buffer)
        diarizer?.append(buffer)
    }

    // MARK: - 分段识别

    private func startNewSegment() {
        guard let recognizer else { return }
        sessionID += 1
        let id = sessionID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // 本地识别：不上传、无时长限制。本机没有可用的听写模型时（一直报错）改走在线识别。
        let onDevice = recognizer.supportsOnDeviceRecognition && !forceOnline
        request.requiresOnDeviceRecognition = onDevice
        if onDevice != isOnDevice || id == 1 {
            Log.write("识别段 #\(id)：\(onDevice ? "本地识别" : "在线识别")")
        }
        isOnDevice = onDevice

        requestLock.lock()
        currentRequest = request
        requestLock.unlock()

        sessionStart = Date()
        lastPartialChange = Date()
        partial = ""
        partialStart = nil
        partialWords = []

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                self?.handle(id: id, result: result, error: error)
            }
        }
    }

    /// 结束当前这一段：把已识别文字定稿成一行，旧任务在后台收尾。
    private func finishSegment() {
        requestLock.lock()
        let request = currentRequest
        currentRequest = nil
        requestLock.unlock()
        request?.endAudio()

        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, let task {
            Log.write("定稿[apple] #\(lines.count + 1)：\(text)")
            rawLines.append(CaptionLine(text: text, start: partialWords.first?.start ?? partialStart ?? sessionStart, end: partialWords.last?.end ?? Date(), words: partialWords))
            let id = sessionID
            finishing[id] = (rawLines.count - 1, task, sessionStart)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if let entry = self?.finishing.removeValue(forKey: id) { entry.task.cancel() }
            }
        } else {
            task?.cancel()
        }
        task = nil
        partial = ""
        partialStart = nil
    }

    private func rotate() {
        finishSegment()
        if isRunning { startNewSegment() }
        onChange?()
    }

    private func tick() {
        guard isRunning, task != nil else { return }
        let now = Date()
        let hasText = !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText && now.timeIntervalSince(lastPartialChange) >= silenceCommitInterval {
            rotate()
        } else if now.timeIntervalSince(sessionStart) >= maxSegmentDuration {
            rotate()
        }
    }

    private func handle(id: Int, result: SFSpeechRecognitionResult?, error: Error?) {
        // 已经定稿的旧段：用它的最终结果回填那一行
        if id != sessionID || task == nil {
            guard let entry = finishing[id] else { return }
            if let result {
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty, entry.lineIndex < rawLines.count {
                    rawLines[entry.lineIndex].text = text
                    rawLines[entry.lineIndex].words = timedWords(result.bestTranscription, base: entry.start)
                    onChange?()
                }
                if result.isFinal { finishing.removeValue(forKey: id) }
            }
            if error != nil { finishing.removeValue(forKey: id) }
            return
        }

        // 当前段
        if let result {
            consecutiveErrors = 0
            if isOnDevice { onDeviceGotResult = true; onDeviceFailures = 0 }
            let text = result.bestTranscription.formattedString
            partialWords = timedWords(result.bestTranscription, base: sessionStart)
            if text != partial {
                if partial.isEmpty {
                    partialStart = partialWords.first?.start ?? Date()
                    Log.write(String(format: "段#%d 首个实时结果（开段后 %.1fs）：%@", id, Date().timeIntervalSince(sessionStart), text))
                }
                partial = text
                lastPartialChange = Date()
                onChange?()
            }
            if result.isFinal {
                rotate()
                return
            }
        }

        if let error {
            let ns = error as NSError
            // 1110 = 这一段里没检测到说话（安静时的正常情况），不算故障
            let noSpeech = ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110
            Log.write("识别错误 段#\(id) \(isOnDevice ? "本地" : "在线")：domain=\(ns.domain) code=\(ns.code) \(ns.localizedDescription)\(noSpeech ? "（没检测到说话）" : "")")
            if !noSpeech { consecutiveErrors += 1 }
            finishSegment()
            onChange?()
            guard isRunning else { return }

            // 本地识别从没出过结果又一直报错：多半是本机没下载听写模型，改走在线识别
            if isOnDevice && !onDeviceGotResult && !noSpeech {
                onDeviceFailures += 1
                if onDeviceFailures >= 2 {
                    Log.write("本地识别连续失败 \(onDeviceFailures) 次且从未出过结果 → 改用在线识别")
                    forceOnline = true
                    consecutiveErrors = 0
                }
            }

            if consecutiveErrors >= 8 {
                Log.write("连续 \(consecutiveErrors) 次识别错误，停止")
                stop()
                onFatalError?(TranscriberError(
                    message: "语音识别反复出错：\(error.localizedDescription)\n\n可尝试：在「系统设置 → 键盘 → 听写」中开启听写；检查网络；或换一种识别语言。",
                    settingsAnchor: nil))
                return
            }
            // 常见情况是「没检测到说话」（1110），直接开新的一段即可
            let delay = consecutiveErrors > 2 ? 1.0 : 0.05
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, self.task == nil else { return }
                self.startNewSegment()
            }
        }
    }

    private func timedWords(_ transcription: SFTranscription, base: Date) -> [CaptionWord] {
        let text = transcription.formattedString as NSString
        return transcription.segments.enumerated().compactMap { i, segment in
            let lo = i == 0 ? 0 : segment.substringRange.location
            let hi = i + 1 < transcription.segments.count ? transcription.segments[i + 1].substringRange.location : text.length
            guard lo >= 0, hi >= lo, hi <= text.length else { return nil }
            return CaptionWord(text: text.substring(with: NSRange(location: lo, length: hi - lo)),
                               start: base.addingTimeInterval(segment.timestamp),
                               end: base.addingTimeInterval(segment.timestamp + segment.duration))
        }
    }

    // MARK: - 导出

    func plainText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return lines.map { "[\(formatter.string(from: $0.start))] \($0.labeledText)" }.joined(separator: "\n") + "\n"
    }

    func srt() -> String {
        let base = origin ?? lines.first?.start ?? Date()
        func stamp(_ t: TimeInterval) -> String {
            let ms = max(0, Int((t * 1000).rounded()))
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        var out = ""
        for (i, line) in lines.enumerated() {
            let start = line.start.timeIntervalSince(base)
            let end = max(line.end.timeIntervalSince(base), start + 1)
            out += "\(i + 1)\n\(stamp(start)) --> \(stamp(end))\n\(line.labeledText)\n\n"
        }
        return out
    }
}
