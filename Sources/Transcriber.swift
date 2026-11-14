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

    private(set) var lines: [CaptionLine] = []
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
    private var finishing: [Int: (lineIndex: Int, task: SFSpeechRecognitionTask)] = [:]
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

    // MARK: - 开始 / 停止

    func start(localeID: String, source: AudioSourceKind,
               engine: RecognitionEngine = .apple, whisper: WhisperSettings? = nil) {
        guard !isRunning, !isStarting, !isFinishing else { return }
        isStarting = true
        startToken += 1
        let token = startToken
        self.source = source
        let useWhisper = engine == .whisper && whisper != nil

        requestPermissions(for: source, needsSpeechRecognition: !useWhisper) { [weak self] error in
            guard let self, token == self.startToken else { return }
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
                self.onFatalError?(TranscriberError(message: "系统不支持该识别语言：\(localeID)", settingsAnchor: nil))
                return
            }
            guard recognizer.isAvailable else {
                self.onFatalError?(TranscriberError(
                    message: "语音识别暂时不可用。\n请确认已联网，或在「系统设置 → 键盘 → 听写」中开启听写后重试。",
                    settingsAnchor: nil))
                return
            }
            self.recognitionEngine = .apple
            self.recognizer = recognizer
            self.isOnDevice = recognizer.supportsOnDeviceRecognition
            self.isRunning = true
            self.consecutiveErrors = 0
            if self.origin == nil { self.origin = Date() }
            self.startNewSegment()
            self.startAudioOrFail()

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
        streamer.onPartial = { [weak self] text in
            guard let self else { return }
            if self.partial.isEmpty && !text.isEmpty { self.partialStart = Date() }
            self.partial = text
            self.onChange?()
        }
        streamer.onCommit = { [weak self] text, start, end in
            guard let self else { return }
            self.lines.append(CaptionLine(text: text, start: start, end: end))
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
        onStateChange?(true)
        onChange?()
    }

    private func startAudioOrFail() {
        startAudio { [weak self] error in
            guard let self else { return }
            if let error {
                self.stop()
                self.onFatalError?(error)
            }
        }
    }

    /// 停止识别。completion 在所有文字都定稿后调用（Whisper 需要再识别完最后一句）。
    func stop(completion: (() -> Void)? = nil) {
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
            streamer.finish { [weak self] in
                guard let self else { return }
                self.isFinishing = false
                self.partial = ""
                self.onChange?()
                completion?()
            }
            return
        }

        finishSegment()
        onStateChange?(false)
        onChange?()
        completion?()
    }

    func clear() {
        for entry in finishing.values { entry.task.cancel() }
        finishing.removeAll()
        lines.removeAll()
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
        switch source {
        case .microphone:
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
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
                DispatchQueue.main.async {
                    completion(message.map { TranscriberError(message: $0, settingsAnchor: "Privacy_ScreenCapture") })
                }
            }
        }
    }

    private func stopMic() {
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
        requestLock.lock()
        let request = currentRequest
        let streamer = activeStreamer
        requestLock.unlock()
        request?.append(buffer)
        streamer?.append(buffer)
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
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true   // 本地识别：不上传、无时长限制
        }

        requestLock.lock()
        currentRequest = request
        requestLock.unlock()

        sessionStart = Date()
        lastPartialChange = Date()
        partial = ""
        partialStart = nil

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
            lines.append(CaptionLine(text: text, start: partialStart ?? sessionStart, end: Date()))
            let id = sessionID
            finishing[id] = (lines.count - 1, task)
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
                if !text.isEmpty, entry.lineIndex < lines.count, lines[entry.lineIndex].text != text {
                    lines[entry.lineIndex].text = text
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
            let text = result.bestTranscription.formattedString
            if text != partial {
                if partial.isEmpty { partialStart = Date() }
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
            consecutiveErrors += 1
            finishSegment()
            onChange?()
            guard isRunning else { return }

            if consecutiveErrors >= 8 {
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

    // MARK: - 导出

    func plainText() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return lines.map { "[\(formatter.string(from: $0.start))] \($0.text)" }.joined(separator: "\n") + "\n"
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
            out += "\(i + 1)\n\(stamp(start)) --> \(stamp(end))\n\(line.text)\n\n"
        }
        return out
    }
}
