import AppKit
import Speech
import UniformTypeIdentifiers
import Carbon

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private var statusItem: NSStatusItem!
    private var panel: SubtitlePanel!
    private let transcriber = Transcriber()
    private let bridge = AgentBridge()
    private let recording = RecordingFile()
    private let dashboard = DashboardServer()
    /// 最近一次错误（给控制台显示）
    private var lastError: (id: Int, message: String)?
    private var whisperPreloadStatus: String?
    private var launchedByURL = false
    private var hotKey: HotKey?
    private var recordHotKey: HotKey?

    /// 记录状态：没有记录 / 录音中 / 已暂停（文件还开着，继续会接着写）
    private enum RecordState { case idle, recording, paused }
    private var recordState: RecordState {
        if transcriber.isRunning || transcriber.isStarting { return .recording }
        return recording.url != nil ? .paused : .idle
    }
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard

    private let languages: [(id: String, name: String)] = [
        ("zh-CN", "中文（普通话）"),
        ("zh-TW", "中文（台湾）"),
        ("zh-HK", "粤语（香港）"),
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("en-IN", "English (India) 印度英语"),
        ("hi-IN", "हिन्दी 印地语"),
        ("ja-JP", "日本語"),
        ("ko-KR", "한국어"),
        ("fr-FR", "Français"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
    ]
    private let fontSizes: [(size: CGFloat, name: String)] = [(22, "小"), (30, "中"), (40, "大"), (54, "特大")]
    private let opacities: [(value: CGFloat, name: String)] = [(0, "透明"), (0.35, "浅"), (0.6, "中"), (0.85, "深")]

    // MARK: - 设置（自动保存）

    private var localeID: String {
        get { defaults.string(forKey: "locale") ?? "zh-CN" }
        set { defaults.set(newValue, forKey: "locale") }
    }
    private var source: AudioSourceKind {
        get { AudioSourceKind(rawValue: defaults.string(forKey: "source") ?? "") ?? .microphone }
        set { defaults.set(newValue.rawValue, forKey: "source") }
    }
    private var fontSize: CGFloat {
        get { let v = defaults.double(forKey: "fontSize"); return v > 0 ? CGFloat(v) : 30 }
        set { defaults.set(Double(newValue), forKey: "fontSize") }
    }
    private var opacity: CGFloat {
        get { defaults.object(forKey: "opacity") == nil ? 0.6 : CGFloat(defaults.double(forKey: "opacity")) }
        set { defaults.set(Double(newValue), forKey: "opacity") }
    }
    private var recognitionEngine: RecognitionEngine {
        get { RecognitionEngine(rawValue: defaults.string(forKey: "engine") ?? "") ?? .apple }
        set { defaults.set(newValue.rawValue, forKey: "engine") }
    }
    private var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? WhisperEngine.defaultModel }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }
    /// Whisper 自动检测语言（适合中英混说）；关闭时按「识别语言」固定
    private var whisperAutoLanguage: Bool {
        get { defaults.bool(forKey: "whisperAutoLanguage") }
        set { defaults.set(newValue, forKey: "whisperAutoLanguage") }
    }

    /// 新记录怎么起名："pattern" 按命名规则自动起名；"ask" 开始前先问名字
    private var namingMode: String {
        get { defaults.string(forKey: "namingMode") == "ask" ? "ask" : "pattern" }
        set { defaults.set(newValue == "ask" ? "ask" : "pattern", forKey: "namingMode") }
    }
    private var namePattern: String {
        get {
            let saved = (defaults.string(forKey: "namePattern") ?? "").trimmingCharacters(in: .whitespaces)
            return saved.isEmpty ? RecordingFile.defaultPattern : saved
        }
        set { defaults.set(newValue, forKey: "namePattern") }
    }
    private var nameContext: RecordingFile.NameContext {
        RecordingFile.NameContext(source: source == .microphone ? "麦克风" : "系统声音",
                                  language: languages.first { $0.id == localeID }?.name ?? localeID)
    }

    /// 本次记录已经录了多久（不算暂停的时间）
    private var activeSince: Date?
    private var accumulatedSeconds: TimeInterval = 0
    private var elapsedSeconds: TimeInterval {
        accumulatedSeconds + (recordState == .recording ? activeSince.map { Date().timeIntervalSince($0) } ?? 0 : 0)
    }
    private func stopClock() {
        if let since = activeSince { accumulatedSeconds += Date().timeIntervalSince(since) }
        activeSince = nil
    }
    /// 记录列表里每个文件的第一句话（按修改时间缓存）
    private var snippetCache: [String: (modified: Date, text: String)] = [:]

    private var whisperSettings: WhisperSettings {
        let code: String
        switch localeID {
        case "zh-HK": code = "yue"
        default: code = String(localeID.prefix(2))   // zh-CN → zh, en-IN → en, hi-IN → hi …
        }
        return WhisperSettings(model: whisperModel,
                               language: whisperAutoLanguage ? nil : code,
                               simplifiedChinese: localeID == "zh-CN")
    }

    private func startTranscriber() {
        transcriber.start(localeID: localeID, source: source,
                          engine: recognitionEngine, whisper: whisperSettings)
    }

    private var clickThrough: Bool {
        get { defaults.bool(forKey: "clickThrough") }
        set { defaults.set(newValue, forKey: "clickThrough") }
    }

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 只在菜单栏显示，不占 Dock
        installMainMenu()

        // ⌥⌘A：在任何地方把字幕发给你的桌面 AI
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.sendToAI(.transcriptOnly)
        }
        // ⌥⌘P：开始新记录 / 暂停 / 继续
        recordHotKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleRecording()
        }

        panel = SubtitlePanel()
        panel.subtitleView.fontSize = fontSize
        panel.subtitleView.backgroundOpacity = opacity
        panel.ignoresMouseEvents = clickThrough
        panel.subtitleView.menu = menu            // 字幕条上右键 = 同一个菜单
        panel.orderFrontRegardless()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        updateStatusIcon()

        transcriber.onChange = { [weak self] in
            guard let self else { return }
            self.refreshSubtitle()
            self.recording.linesChanged(self.transcriber.lines)
        }
        transcriber.onStateChange = { [weak self] running in
            if !running, let self { self.recording.flush(lines: self.transcriber.lines) }
            self?.updateStatusIcon()
            self?.refreshSubtitle()
        }
        transcriber.onFatalError = { [weak self] error in
            guard let self else { return }
            // 一句都还没录到就失败了（比如没给权限）：这次记录作废，不留空文件
            if !self.transcriber.isRunning && self.transcriber.lines.isEmpty {
                self.recording.end(lines: [])
            }
            self.updateStatusIcon()
            self.showError(error)
        }

        refreshSubtitle()

        Log.startSession()
        Log.write("日志文件 \(Log.fileURL.path)")
        startDashboard()
        // 稍等一下再决定要不要打开控制台：如果是控制台页面上的「打开 LiveCaption」把应用叫起来的，
        // 那个页面会自己恢复，不用再开一个标签页
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.dashboardOnLaunch, !self.launchedByURL,
                  !self.defaults.bool(forKey: "autostart") else { return }
            self.openDashboard()
        }
        // 调试用：open LiveCaption.app --args -autostart YES  启动后立刻开始新记录
        if defaults.bool(forKey: "autostart") {
            DispatchQueue.main.async { [weak self] in self?.beginNewRecording(title: nil) }
        }
    }

    /// livecaption://open —— 控制台页面在应用没运行时用它把应用叫起来；启动本身就是全部要做的事
    func application(_ application: NSApplication, open urls: [URL]) {
        launchedByURL = true
        Log.write("通过链接打开：\(urls.map(\.absoluteString).joined(separator: " "))")
    }

    /// 应用已在运行时再次打开它（访达 / 启动台里双击）：打开控制台
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        transcriber.stop()
        recording.end(lines: transcriber.lines)
    }

    // MARK: - 字幕显示

    private func refreshSubtitle() {
        let view = panel.subtitleView
        let lines = transcriber.lines
        let partial = transcriber.partial.trimmingCharacters(in: .whitespacesAndNewlines)

        if let status = transcriber.statusMessage, partial.isEmpty {
            view.set(previous: "Whisper 高精度识别", current: status)
            return
        }
        if !partial.isEmpty {
            view.set(previous: lines.last?.text ?? "", current: partial)
        } else if let last = lines.last {
            view.set(previous: lines.count >= 2 ? lines[lines.count - 2].text : "", current: last.text)
        } else if transcriber.isRunning {
            view.set(previous: transcriber.recognitionEngine == .whisper ? "Whisper 高精度 · 本地识别"
                        : (transcriber.isOnDevice ? "本地识别 · 不上传音频" : "在线识别"),
                     current: source == .microphone ? "正在聆听…请开始说话" : "正在收听系统声音…")
        } else {
            view.set(previous: "LiveCaption 实时字幕",
                     current: "按 ⌥⌘P 开始记录")
        }
        if let toast = activeToast, partial.isEmpty {
            view.set(previous: "LiveCaption", current: toast)
            return
        }
        if recordState == .paused && partial.isEmpty {
            view.set(previous: "⏸ 已暂停 · 继续后接着写入 \(recording.displayName)",
                     current: lines.last?.text ?? "按 ⌥⌘P 继续")
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let name: String
        switch recordState {
        case .recording: name = "captions.bubble.fill"
        case .paused: name = "pause.circle"
        case .idle: name = "captions.bubble"
        }
        let metering = transcriber.isRunning
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "LiveCaption") {
            button.image = metering
                ? Self.iconWithMeter(symbol, level: CGFloat(displayedLevel), receiving: transcriber.isReceivingAudio)
                : { symbol.isTemplate = true; return symbol }()
            button.title = ""
        } else {
            button.title = transcriber.isRunning ? "字幕●" : "字幕"
        }
        button.toolTip = metering
            ? (transcriber.isReceivingAudio ? "右侧竖条 = 输入音量。说话时会跳动；跳动但没字幕 = 收到声音但没识别出来"
                                            : "没有收到任何声音：检查麦克风 / 音频来源和权限")
            : nil

        // 记录时每 0.1 秒刷新音量条
        if metering, levelTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.levelTick() }
            RunLoop.main.add(timer, forMode: .common)
            levelTimer = timer
        } else if !metering, levelTimer != nil {
            levelTimer?.invalidate()
            levelTimer = nil
            displayedLevel = 0
        }
    }

    // MARK: - 菜单栏音量条

    private var levelTimer: Timer?
    private var displayedLevel: Float = 0

    private func levelTick() {
        // 上升立刻跟上，下降慢慢回落，看起来更稳
        let level = transcriber.inputLevel
        displayedLevel = level > displayedLevel ? level : max(level, displayedLevel - 0.08)
        updateStatusIcon()
    }

    /// 图标 + 右侧竖直音量条（模板图，自动适应深浅色菜单栏）。
    /// 条里有填充 = 收到声音；空心框 = 收到的是静音；虚线框 = 完全没有音频数据。
    private static func iconWithMeter(_ symbol: NSImage, level: CGFloat, receiving: Bool) -> NSImage {
        let icon = symbol.size
        let barWidth: CGFloat = 5, gap: CGFloat = 3
        let height = max(icon.height, 16)
        let size = NSSize(width: icon.width + gap + barWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: (height - icon.height) / 2, width: icon.width, height: icon.height))
            let frame = NSRect(x: icon.width + gap + 0.5, y: 1.5, width: barWidth - 1, height: height - 3)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 1.5, yRadius: 1.5)
            outline.lineWidth = 1
            if !receiving { outline.setLineDash([1.5, 1.5], count: 2, phase: 0) }
            NSColor.black.withAlphaComponent(receiving ? 0.45 : 0.8).setStroke()
            outline.stroke()
            if receiving, level > 0.02 {
                let inner = frame.insetBy(dx: 1, dy: 1)
                let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width,
                                  height: max(1, inner.height * min(1, level)))
                NSColor.black.setFill()
                NSBezierPath(rect: fill).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// 菜单里的一行文字说明：区分「没收到声音」和「收到声音但没识别出来」
    private var audioStatusText: String {
        guard transcriber.isRunning else { return "" }
        if !transcriber.isReceivingAudio {
            return "⚠️ 没有收到音频数据（检查\(source == .microphone ? "麦克风" : "系统录音")权限 / 输入设备）"
        }
        let level = transcriber.inputLevel
        if level < 0.1 { return "输入音量：几乎无声（收到的是静音）" }
        return "输入音量：\(Int(level * 100))%  收到声音 ✓"
    }

    // MARK: - 菜单（每次打开时重建，状态总是最新）

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()

        if let url = dashboard.url {
            menu.addItem(item("打开控制台（\(url.host ?? "localhost"):\(dashboard.port)）", #selector(openDashboard)))
            menu.addItem(.separator())
        }

        switch recordState {
        case .idle:
            let start = item("● 开始新记录", #selector(startNewRecording))
            start.keyEquivalent = "p"
            start.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(start)
            let continueMenu = NSMenu()
            continueMenu.autoenablesItems = false
            let recent = recording.recentFiles()
            if recent.isEmpty {
                let none = item("（还没有记录文件）", nil)
                none.isEnabled = false
                continueMenu.addItem(none)
            }
            for file in recent {
                let it = item("\(file.url.lastPathComponent)    \(RecordingFile.fullFormatter.string(from: file.modified))",
                              #selector(continueRecentFile(_:)))
                it.representedObject = file.url.path
                continueMenu.addItem(it)
            }
            continueMenu.addItem(.separator())
            continueMenu.addItem(item("选择其他文件…", #selector(chooseFileToContinue)))
            menu.addItem(submenu("○ 接着写入已有文件", continueMenu))

        case .recording:
            let pause = item("⏸ 暂停", #selector(pauseRecording))
            pause.keyEquivalent = "p"
            pause.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(pause)
            menu.addItem(item("⏹ 结束本次记录", #selector(endRecording)))
            let info = item("正在写入：\(recording.displayName)", nil)
            info.isEnabled = false
            menu.addItem(info)
            if transcriber.isRunning {
                let audio = item(audioStatusText, nil)
                audio.isEnabled = false
                menu.addItem(audio)
            }

        case .paused:
            let resume = item("▶︎ 继续（接着写入 \(recording.displayName)）", #selector(resumeRecording))
            resume.keyEquivalent = "p"
            resume.keyEquivalentModifierMask = [.command, .option]
            menu.addItem(resume)
            menu.addItem(item("⏹ 结束本次记录", #selector(endRecording)))
        }
        menu.addItem(.separator())

        // 交给桌面 AI
        let target = bridge.selectedApp
        let aiMenu = NSMenu()
        aiMenu.autoenablesItems = false
        for request in [AgentBridge.Request.transcriptOnly, .summarize, .actionItems] {
            let it = item(request.title, #selector(sendToAIItem(_:)))
            it.representedObject = request.title
            if request == .transcriptOnly {
                it.keyEquivalent = "a"
                it.keyEquivalentModifierMask = [.command, .option]
            }
            aiMenu.addItem(it)
        }
        aiMenu.addItem(.separator())
        aiMenu.addItem(item("在访达中显示字幕文件", #selector(revealTranscriptFolder)))
        aiMenu.addItem(item("复制字幕文件路径", #selector(copyTranscriptPath)))
        aiMenu.addItem(.separator())
        let header = item("AI 应用：", nil)
        header.isEnabled = false
        aiMenu.addItem(header)
        for app in bridge.installedApps() {
            let it = item("    " + app.name, #selector(selectAIApp(_:)))
            it.representedObject = app.url.path
            it.state = app.url.path == target?.url.path ? .on : .off
            aiMenu.addItem(it)
        }
        if let target, !bridge.installedApps().contains(where: { $0.url.path == target.url.path }) {
            let it = item("    " + target.name, #selector(selectAIApp(_:)))
            it.representedObject = target.url.path
            it.state = .on
            aiMenu.addItem(it)
        }
        aiMenu.addItem(item("    选择其他应用…", #selector(chooseOtherAIApp)))
        menu.addItem(submenu("交给桌面 AI" + (target.map { "（\($0.name)）" } ?? ""), aiMenu))
        menu.addItem(.separator())

        // 音频来源
        let sourceMenu = NSMenu()
        for (kind, title) in [(AudioSourceKind.microphone, "麦克风"), (.systemAudio, "系统声音（视频 / 会议 / 直播）")] {
            let it = item(title, #selector(selectSource(_:)))
            it.representedObject = kind.rawValue
            it.state = kind == source ? .on : .off
            sourceMenu.addItem(it)
        }
        menu.addItem(submenu("音频来源", sourceMenu))

        // 识别语言
        let supported = Set(SFSpeechRecognizer.supportedLocales().map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })
        let langMenu = NSMenu()
        langMenu.autoenablesItems = false
        for lang in languages {
            let it = item(lang.name, #selector(selectLanguage(_:)))
            it.representedObject = lang.id
            it.state = lang.id == localeID ? .on : .off
            it.isEnabled = supported.isEmpty || supported.contains(lang.id)
            langMenu.addItem(it)
        }
        menu.addItem(submenu("识别语言", langMenu))

        // 识别引擎
        let engineMenu = NSMenu()
        engineMenu.autoenablesItems = false
        for (kind, title) in [(RecognitionEngine.apple, "系统识别（快、省电）"),
                              (.whisper, "Whisper 高精度（口音、中英混说更准）")] {
            let it = item(title, #selector(selectEngine(_:)))
            it.representedObject = kind.rawValue
            it.state = kind == recognitionEngine ? .on : .off
            engineMenu.addItem(it)
        }
        engineMenu.addItem(.separator())
        let modelHeader = item("Whisper 模型：", nil)
        modelHeader.isEnabled = false
        engineMenu.addItem(modelHeader)
        for model in WhisperEngine.models {
            let it = item("    " + model.name, #selector(selectWhisperModel(_:)))
            it.representedObject = model.id
            it.state = model.id == whisperModel ? .on : .off
            engineMenu.addItem(it)
        }
        engineMenu.addItem(.separator())
        let auto = item("Whisper 自动检测语言（多种语言混着说时打开）", #selector(toggleWhisperAutoLanguage))
        auto.state = whisperAutoLanguage ? .on : .off
        engineMenu.addItem(auto)
        let preload = item(WhisperEngine.shared.loadedModel == whisperModel ? "Whisper 模型已就绪 ✓" : "提前下载并加载 Whisper 模型",
                           #selector(preloadWhisper))
        preload.isEnabled = WhisperEngine.shared.loadedModel != whisperModel
        engineMenu.addItem(preload)
        menu.addItem(submenu("识别引擎" + (recognitionEngine == .whisper ? "（Whisper）" : ""), engineMenu))
        menu.addItem(.separator())

        // 字幕条：显示 / 锁定常用，放在外面；外观收进子菜单
        menu.addItem(item(panel.isVisible ? "隐藏字幕条" : "显示字幕条", #selector(toggleWindow)))
        let lock = item("锁定字幕条（鼠标可穿透）", #selector(toggleClickThrough))
        lock.state = clickThrough ? .on : .off
        menu.addItem(lock)

        let lookMenu = NSMenu()
        let fontHeader = item("字号", nil)
        fontHeader.isEnabled = false
        lookMenu.addItem(fontHeader)
        for f in fontSizes {
            let it = item("    " + f.name, #selector(selectFontSize(_:)))
            it.representedObject = Double(f.size)
            it.state = f.size == fontSize ? .on : .off
            lookMenu.addItem(it)
        }
        lookMenu.addItem(.separator())
        let bgHeader = item("背景", nil)
        bgHeader.isEnabled = false
        lookMenu.addItem(bgHeader)
        for o in opacities {
            let it = item("    " + o.name, #selector(selectOpacity(_:)))
            it.representedObject = Double(o.value)
            it.state = o.value == opacity ? .on : .off
            lookMenu.addItem(it)
        }
        lookMenu.addItem(.separator())
        lookMenu.addItem(item("回到默认位置", #selector(resetPosition)))
        menu.addItem(submenu("字幕条外观", lookMenu))
        menu.addItem(.separator())

        // 复制与导出
        let hasLines = !transcriber.lines.isEmpty
        let exportMenu = NSMenu()
        exportMenu.autoenablesItems = false
        for (title, action) in [("复制全部文字", #selector(copyAll)),
                                ("保存为文本（.txt）…", #selector(saveText)),
                                ("导出字幕文件（.srt）…", #selector(saveSRT)),
                                ("清空屏幕上的字幕", #selector(clearAll))] {
            let it = item(title, action)
            // 记录进行中不能清空（文件内容以这些字幕为准）
            it.isEnabled = hasLines && (action != #selector(clearAll) || recordState == .idle)
            exportMenu.addItem(it)
        }
        menu.addItem(submenu("复制与导出（已记录 \(transcriber.lines.count) 句）", exportMenu))
        menu.addItem(.separator())
        menu.addItem(item("退出 LiveCaption", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.submenu = sub
        return it
    }

    // MARK: - 菜单动作

    // MARK: - 交给桌面 AI

    private func sendToAI(_ request: AgentBridge.Request) {
        recording.flush(lines: transcriber.lines)
        let file = transcriptFileForAI()
        let transcript = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? transcriber.lines.map { "[\(RecordingFile.timeFormatter.string(from: $0.start))] \($0.text)" }.joined(separator: "\n")
        showToast(bridge.send(request, transcript: transcript, file: file))
    }

    @objc private func sendToAIItem(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let request = [AgentBridge.Request.transcriptOnly, .summarize, .actionItems].first(where: { $0.title == title })
        else { return }
        sendToAI(request)
    }

    @objc private func selectAIApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        let url = URL(fileURLWithPath: path)
        bridge.selectedApp = AgentBridge.AIApp(name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    @objc private func chooseOtherAIApp() {
        bridge.chooseOtherApp()
    }

    /// 给 AI 用的文件：进行中的记录用它自己的文件，否则用「最新字幕.md」
    private func transcriptFileForAI() -> URL? {
        if let url = recording.url, FileManager.default.fileExists(atPath: url.path) { return url }
        return FileManager.default.fileExists(atPath: recording.latestFile.path) ? recording.latestFile : nil
    }

    @objc private func revealTranscriptFolder() {
        recording.flush(lines: transcriber.lines)
        if let file = transcriptFileForAI() {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? FileManager.default.createDirectory(at: recording.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(recording.folder)
        }
    }

    @objc private func copyTranscriptPath() {
        recording.flush(lines: transcriber.lines)
        let path = (transcriptFileForAI() ?? recording.latestFile).path
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(path, forType: .string)
        showToast("已复制路径：\(path)")
    }

    /// 在字幕条上短暂显示一条提示
    /// 提示显示 4 秒；期间有人说话时字幕优先
    private var activeToast: String?
    private var toastWorkItem: DispatchWorkItem?
    private func showToast(_ text: String) {
        panel.orderFrontRegardless()
        activeToast = text
        refreshSubtitle()
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.activeToast = nil
            self?.refreshSubtitle()
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// 菜单栏应用默认没有主菜单，导致输入框里 ⌘C / ⌘V / ⌘A 无效。这里补一个（不会显示出来）。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 LiveCaption", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: - 记录：开始 / 暂停 / 继续 / 结束

    /// ⌥⌘P：没有记录 → 开始新记录；录音中 → 暂停；暂停中 → 继续
    private func toggleRecording() {
        switch recordState {
        case .idle: startNewRecording()
        case .recording: pauseRecording()
        case .paused: resumeRecording()
        }
    }

    /// 菜单 / 快捷键：按「命名方式」决定要不要先问名字
    @objc private func startNewRecording() {
        guard recordState == .idle else { return }
        if namingMode == "ask" {
            guard let title = askForTitle() else { return }
            beginNewRecording(title: title)
        } else {
            beginNewRecording(title: nil)
        }
    }

    /// title 为空就按命名规则自动起名
    private func beginNewRecording(title: String?) {
        guard recordState == .idle else { return }
        recording.beginNew(title: title, pattern: namePattern, context: nameContext)
        transcriber.clear()
        accumulatedSeconds = 0
        activeSince = Date()
        startTranscriber()
        showToast("开始新记录：\(recording.displayName)")
    }

    /// 弹一个小输入框问名字；取消返回 nil，留空返回空字符串（= 自动起名）
    private func askForTitle() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "给这次记录起个名字"
        alert.informativeText = "留空就按命名规则自动起名，之后也可以随时改。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = RecordingFile.expand(namePattern, date: Date(), context: nameContext)
        alert.accessoryView = field
        alert.addButton(withTitle: "开始记录")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func continueRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        continueRecording(in: URL(fileURLWithPath: path))
    }

    @objc private func chooseFileToContinue() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择要接着写入的文件"
        panel.directoryURL = recording.folder
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            continueRecording(in: url)
        }
    }

    private func continueRecording(in file: URL) {
        guard recordState == .idle else { return }
        do {
            try recording.beginContinuing(file)
        } catch {
            showError(TranscriberError(message: "无法接着写入这个文件：\(error.localizedDescription)", settingsAnchor: nil))
            return
        }
        transcriber.clear()
        accumulatedSeconds = 0
        activeSince = Date()
        startTranscriber()
        showToast("接着写入：\(recording.displayName)")
    }

    @objc private func pauseRecording() {
        guard recordState == .recording else { return }
        stopClock()
        transcriber.stop { [weak self] in
            guard let self else { return }
            self.recording.flush(lines: self.transcriber.lines)
            self.updateStatusIcon()
            self.refreshSubtitle()
        }
    }

    @objc private func resumeRecording() {
        guard recordState == .paused, !transcriber.isFinishing else { return }
        recording.markResume(atLine: transcriber.lines.count)
        activeSince = Date()
        startTranscriber()
    }

    @objc private func endRecording() {
        guard recordState != .idle else { return }
        stopClock()
        // 等最后一句识别完再定稿文件
        transcriber.stop { [weak self] in
            guard let self else { return }
            let wrote = !self.transcriber.lines.isEmpty
            let name = self.recording.displayName
            let file = self.recording.url
            self.recording.end(lines: self.transcriber.lines)
            self.updateStatusIcon()
            self.refreshSubtitle()
            if wrote, let file {
                self.showToast("已结束，记录保存在 文稿/LiveCaption/\(file.lastPathComponent)")
            } else {
                self.showToast("已结束（没有录到内容，\(name) 未改动）")
            }
        }
    }

    private func restartIfRunning() {
        guard transcriber.isRunning || transcriber.isStarting else { return }
        transcriber.stop { [weak self] in self?.startTranscriber() }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = AudioSourceKind(rawValue: raw) else { return }
        source = kind
        restartIfRunning()
        refreshSubtitle()
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = RecognitionEngine(rawValue: raw) else { return }
        recognitionEngine = kind
        restartIfRunning()
    }

    @objc private func selectWhisperModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        whisperModel = id
        if recognitionEngine == .whisper { restartIfRunning() }
    }

    @objc private func toggleWhisperAutoLanguage() {
        whisperAutoLanguage.toggle()
        if recognitionEngine == .whisper { restartIfRunning() }
    }

    /// 会前先把模型下好、加载好，开始记录时就不用等
    @objc private func preloadWhisper() {
        whisperPreloadStatus = "正在准备 Whisper 模型…"
        WhisperEngine.shared.prepare(model: whisperModel, status: { [weak self] message in
            self?.whisperPreloadStatus = message
            self?.showToast(message)
        }) { [weak self] error in
            self?.whisperPreloadStatus = nil
            if let error {
                self?.showError(TranscriberError(message: error, settingsAnchor: nil))
            } else {
                self?.showToast("Whisper 模型已就绪，可以开始记录了")
            }
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        localeID = id
        restartIfRunning()
    }

    @objc private func selectFontSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        fontSize = CGFloat(v)
        panel.subtitleView.fontSize = fontSize
        panel.fitHeightToFont()
    }

    @objc private func selectOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        opacity = CGFloat(v)
        panel.subtitleView.backgroundOpacity = opacity
    }

    @objc private func toggleClickThrough() {
        clickThrough.toggle()
        panel.ignoresMouseEvents = clickThrough
    }

    @objc private func toggleWindow() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func resetPosition() {
        panel.orderFrontRegardless()
        panel.moveToDefaultPosition()
    }

    @objc private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcriber.lines.map(\.text).joined(separator: "\n"), forType: .string)
    }

    @objc private func saveText() { save(transcriber.plainText(), ext: "txt") }
    @objc private func saveSRT() { save(transcriber.srt(), ext: "srt") }

    @objc private func clearAll() {
        transcriber.clear()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func save(_ content: String, ext: String) {
        NSApp.activate(ignoringOtherApps: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "字幕_\(formatter.string(from: Date())).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(TranscriberError(message: "保存失败：\(error.localizedDescription)", settingsAnchor: nil))
        }
    }

    /// 退出并重新打开自己（权限变更后需要）
    private func relaunch() {
        Log.write("重新打开应用")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func showError(_ error: TranscriberError) {
        Log.write("错误弹窗：\(error.message.replacingOccurrences(of: "\n", with: " "))")
        lastError = ((lastError?.id ?? 0) + 1, error.message)
        refreshSubtitle()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LiveCaption"
        alert.informativeText = error.message
        if error.settingsAnchor != nil {
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            // 屏幕录制权限要重启应用才生效
            if error.settingsAnchor == "Privacy_ScreenCapture" { alert.addButton(withTitle: "重新打开 LiveCaption") }
        } else {
            alert.addButton(withTitle: "好")
        }
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn, let anchor = error.settingsAnchor,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        } else if choice == .alertThirdButtonReturn {
            relaunch()
        }
    }
}

// MARK: - 控制台（http://localhost 上的 dashboard）

extension AppDelegate {
    private var dashboardOnLaunch: Bool {
        get { defaults.object(forKey: "dashboardOnLaunch") == nil ? true : defaults.bool(forKey: "dashboardOnLaunch") }
        set { defaults.set(newValue, forKey: "dashboardOnLaunch") }
    }

    /// 应用图标的 PNG（控制台页面的标签页图标和标题旁的小图标）
    private static let iconPNG: Data? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep, let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }()

    private func startDashboard() {
        dashboard.handler = { [weak self] request in
            self?.handleDashboard(request) ?? .error(404, "not found")
        }
        dashboard.start()
    }

    @objc private func openDashboard() {
        guard let url = dashboard.url else {
            showError(TranscriberError(message: "控制台没有启动成功（本机端口被占用）。详见 \(Log.fileURL.path)", settingsAnchor: nil))
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func handleDashboard(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .text(DashboardPage.html, type: "text/html; charset=utf-8")
        case ("GET", "/icon.png"):
            guard let png = Self.iconPNG else { return .error(404, "not found") }
            return HTTPResponse(contentType: "image/png", body: png)
        case ("GET", "/api/state"):
            return .json(dashboardState())
        case ("GET", "/api/recordings"):
            return .json(["recordings": dashboardRecordings()])
        case ("GET", "/api/recording"):
            guard let url = recordingURL(named: request.query["name"] ?? ""),
                  let text = try? String(contentsOf: url, encoding: .utf8) else {
                return .error(404, "找不到这个记录文件")
            }
            return .json(["name": url.lastPathComponent, "text": text])
        case ("POST", "/api/action"):
            return dashboardAction(request.json)
        case ("POST", "/api/settings"):
            return dashboardApplySettings(request.json)
        default:
            return .error(404, "not found")
        }
    }

    // MARK: 状态

    private func dashboardState() -> [String: Any] {
        let state: String
        switch recordState {
        case .idle: state = "idle"
        case .recording: state = "recording"
        case .paused: state = "paused"
        }
        let supported = Set(SFSpeechRecognizer.supportedLocales().map {
            $0.identifier.replacingOccurrences(of: "_", with: "-")
        })
        let lines = transcriber.lines
        let whisper = WhisperEngine.shared
        var result: [String: Any] = [
            "state": state,
            "starting": transcriber.isStarting,
            "finishing": transcriber.isFinishing,
            "running": transcriber.isRunning,
            "status": transcriber.statusMessage ?? "",
            "receiving": transcriber.isReceivingAudio,
            "level": Double(transcriber.inputLevel),
            "onDevice": transcriber.isOnDevice,
            "activeEngine": transcriber.recognitionEngine.rawValue,
            "currentFile": recording.displayName,
            "elapsed": Int(elapsedSeconds),
            "naming": [
                "mode": namingMode,
                "pattern": namePattern,
                "defaultPattern": RecordingFile.defaultPattern,
                "preview": RecordingFile.expand(namePattern, date: Date(), context: nameContext) + ".md",
                "tokens": RecordingFile.patternTokens.map { ["token": $0.token, "note": $0.note] },
            ] as [String: Any],
            "lineCount": lines.count,
            "lines": lines.suffix(200).map { ["time": RecordingFile.timeFormatter.string(from: $0.start), "text": $0.text] },
            "partial": transcriber.partial.trimmingCharacters(in: .whitespacesAndNewlines),
            "folder": recording.folder.path,
            "settings": [
                "source": source.rawValue,
                "locale": localeID,
                "engine": recognitionEngine.rawValue,
                "whisperModel": whisperModel,
                "whisperAuto": whisperAutoLanguage,
                "fontSize": Double(fontSize),
                "opacity": Double(opacity),
                "clickThrough": clickThrough,
                "panelVisible": panel.isVisible,
                "dashboardOnLaunch": dashboardOnLaunch,
            ],
            "options": [
                "sources": [["id": "microphone", "name": "麦克风"],
                            ["id": "systemAudio", "name": "系统声音（视频 / 会议 / 直播）"]],
                "languages": languages.map {
                    ["id": $0.id, "name": $0.name, "supported": supported.isEmpty || supported.contains($0.id)] as [String: Any]
                },
                "engines": [["id": "apple", "name": "系统识别", "note": "快、省电，本机识别"],
                            ["id": "whisper", "name": "Whisper 高精度", "note": "口音、中英混说更准，首次需下载模型"]],
                "models": WhisperEngine.models.map { model -> [String: Any] in
                    let saved = defaults.string(forKey: "whisperFolder.\(model.id)")
                    let downloaded = saved.map { FileManager.default.fileExists(atPath: $0) } ?? false
                    return ["id": model.id, "name": model.name, "downloaded": downloaded,
                            "loaded": whisper.loadedModel == model.id]
                },
                "fontSizes": fontSizes.map { ["value": Double($0.size), "name": $0.name] as [String: Any] },
                "opacities": opacities.map { ["value": Double($0.value), "name": $0.name] as [String: Any] },
            ],
            "whisper": [
                "loadedModel": whisper.loadedModel ?? "",
                "loading": whisper.isLoading,
                "status": whisperPreloadStatus ?? transcriber.statusMessage ?? "",
            ],
            "ai": [
                "app": bridge.selectedApp?.name ?? "",
                "requests": [AgentBridge.Request.transcriptOnly, .summarize, .actionItems].map(\.title),
            ],
        ]
        if let lastError { result["error"] = ["id": lastError.id, "message": lastError.message] }
        return result
    }

    // MARK: 记录文件

    private func dashboardRecordings() -> [[String: Any]] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: recording.folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let latest = recording.latestFile.lastPathComponent
        return items
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent != latest }
            .map { url -> (URL, Date, Int) in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(300)
            .map { ["name": $0.0.lastPathComponent,
                    "modified": RecordingFile.fullFormatter.string(from: $0.1),
                    "ts": Int($0.1.timeIntervalSince1970),
                    "size": $0.2,
                    "snippet": snippet(of: $0.0, modified: $0.1),
                    "active": $0.0.lastPathComponent == recording.displayName] }
    }

    /// 记录里的第一句话，给列表当摘要
    private func snippet(of url: URL, modified: Date) -> String {
        if let cached = snippetCache[url.path], cached.modified == modified { return cached.text }
        var text = ""
        if let handle = try? FileHandle(forReadingFrom: url) {
            let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
            try? handle.close()
            let lines = head.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            if let cue = lines.first(where: { $0.range(of: #"^\[\d{1,2}:\d{2}(:\d{2})?\]\s*\S"#, options: .regularExpression) != nil }),
               let close = cue.firstIndex(of: "]") {
                text = String(cue[cue.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else {
                text = lines.first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("开始时间") && !$0.hasPrefix("（") } ?? ""
            }
        }
        text = String(text.prefix(120))
        snippetCache[url.path] = (modified, text)
        return text
    }

    /// 只允许访问记录文件夹里的 .md / .txt（文件名不能带路径）
    private func recordingURL(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
              ["md", "txt"].contains((name as NSString).pathExtension.lowercased()) else { return nil }
        let url = recording.folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: 动作

    private func dashboardAction(_ body: [String: Any]) -> HTTPResponse {
        let action = body["action"] as? String ?? ""
        Log.write("控制台动作：\(action)")
        var extra: [String: Any] = [:]
        switch action {
        case "start": beginNewRecording(title: body["title"] as? String)   // 名字在页面上已经问过了
        case "rename":
            guard let url = recordingURL(named: body["name"] as? String ?? "") ?? currentUnwrittenFile(named: body["name"] as? String) else {
                return .error(404, "找不到这个记录文件")
            }
            do {
                extra["renamed"] = try recording.rename(url, to: body["to"] as? String ?? "").lastPathComponent
            } catch {
                return .error(409, error.localizedDescription)
            }
        case "trash":
            guard let url = recordingURL(named: body["name"] as? String ?? "") else { return .error(404, "找不到这个记录文件") }
            guard url.lastPathComponent != recording.displayName else { return .error(409, "这份记录还在进行中，请先结束。") }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                return .error(409, "没能移到废纸篓：\(error.localizedDescription)")
            }
        case "pause": pauseRecording()
        case "resume": resumeRecording()
        case "end": endRecording()
        case "continue":
            guard let url = recordingURL(named: body["name"] as? String ?? "") else { return .error(404, "找不到这个记录文件") }
            guard recordState == .idle else { return .error(409, "请先结束当前记录") }
            continueRecording(in: url)
        case "reveal":
            if let url = recordingURL(named: body["name"] as? String ?? "") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                revealTranscriptFolder()
            }
        case "preloadWhisper": preloadWhisper()
        case "sendToAI":
            let title = body["request"] as? String ?? ""
            guard let request = [AgentBridge.Request.transcriptOnly, .summarize, .actionItems].first(where: { $0.title == title })
            else { return .error(400, "未知的请求") }
            sendToAI(request)
        case "resetPosition": resetPosition()
        case "dismissError": lastError = nil
        default:
            return .error(400, "未知的动作：\(action)")
        }
        return .json(dashboardState().merging(extra) { _, new in new })
    }

    /// 正在进行、但还没说第一句话（文件还没落盘）的那份记录：也允许改名
    private func currentUnwrittenFile(named name: String?) -> URL? {
        guard let url = recording.url, url.lastPathComponent == name else { return nil }
        return url
    }

    private func dashboardApplySettings(_ body: [String: Any]) -> HTTPResponse {
        Log.write("控制台设置：\(body)")
        if let raw = body["source"] as? String, let kind = AudioSourceKind(rawValue: raw), kind != source {
            source = kind
            restartIfRunning()
        }
        if let id = body["locale"] as? String, languages.contains(where: { $0.id == id }), id != localeID {
            localeID = id
            restartIfRunning()
        }
        if let raw = body["engine"] as? String, let kind = RecognitionEngine(rawValue: raw), kind != recognitionEngine {
            recognitionEngine = kind
            restartIfRunning()
        }
        if let id = body["whisperModel"] as? String, WhisperEngine.models.contains(where: { $0.id == id }), id != whisperModel {
            whisperModel = id
            if recognitionEngine == .whisper { restartIfRunning() }
        }
        if let auto = body["whisperAuto"] as? Bool, auto != whisperAutoLanguage {
            whisperAutoLanguage = auto
            if recognitionEngine == .whisper { restartIfRunning() }
        }
        if let size = body["fontSize"] as? Double, fontSizes.contains(where: { Double($0.size) == size }) {
            fontSize = CGFloat(size)
            panel.subtitleView.fontSize = fontSize
            panel.fitHeightToFont()
        }
        if let value = body["opacity"] as? Double, (0...1).contains(value) {
            opacity = CGFloat(value)
            panel.subtitleView.backgroundOpacity = opacity
        }
        if let locked = body["clickThrough"] as? Bool {
            clickThrough = locked
            panel.ignoresMouseEvents = locked
        }
        if let visible = body["panelVisible"] as? Bool {
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
        if let open = body["dashboardOnLaunch"] as? Bool { dashboardOnLaunch = open }
        if let mode = body["namingMode"] as? String { namingMode = mode }
        if let pattern = body["namePattern"] as? String { namePattern = String(pattern.prefix(120)) }
        refreshSubtitle()
        return .json(dashboardState())
    }
}
