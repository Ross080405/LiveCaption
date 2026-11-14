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
                     current: "右键这里或点菜单栏图标 → 开始新记录（⌥⌘P）")
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
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: "LiveCaption") {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            button.title = transcriber.isRunning ? "字幕●" : "字幕"
        }
    }

    // MARK: - 菜单（每次打开时重建，状态总是最新）

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()

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

        // 外观
        let fontMenu = NSMenu()
        for f in fontSizes {
            let it = item(f.name, #selector(selectFontSize(_:)))
            it.representedObject = Double(f.size)
            it.state = f.size == fontSize ? .on : .off
            fontMenu.addItem(it)
        }
        menu.addItem(submenu("字号", fontMenu))

        let bgMenu = NSMenu()
        for o in opacities {
            let it = item(o.name, #selector(selectOpacity(_:)))
            it.representedObject = Double(o.value)
            it.state = o.value == opacity ? .on : .off
            bgMenu.addItem(it)
        }
        menu.addItem(submenu("背景", bgMenu))

        let lock = item("锁定字幕条（鼠标可穿透）", #selector(toggleClickThrough))
        lock.state = clickThrough ? .on : .off
        menu.addItem(lock)
        menu.addItem(item(panel.isVisible ? "隐藏字幕条" : "显示字幕条", #selector(toggleWindow)))
        menu.addItem(item("字幕条回到默认位置", #selector(resetPosition)))
        menu.addItem(.separator())

        // 记录
        let hasLines = !transcriber.lines.isEmpty
        let count = item("已记录 \(transcriber.lines.count) 句", nil)
        count.isEnabled = false
        menu.addItem(count)
        for (title, action) in [("复制全部文字", #selector(copyAll)),
                                ("保存为文本（.txt）…", #selector(saveText)),
                                ("导出字幕文件（.srt）…", #selector(saveSRT)),
                                ("清空屏幕上的字幕", #selector(clearAll))] {
            let it = item(title, action)
            // 记录进行中不能清空（文件内容以这些字幕为准）
            it.isEnabled = hasLines && (action != #selector(clearAll) || recordState == .idle)
            menu.addItem(it)
        }
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

    @objc private func startNewRecording() {
        guard recordState == .idle else { return }
        recording.beginNew()
        transcriber.clear()
        startTranscriber()
        showToast("开始新记录：\(recording.displayName)")
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
        startTranscriber()
        showToast("接着写入：\(recording.displayName)")
    }

    @objc private func pauseRecording() {
        guard recordState == .recording else { return }
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
        startTranscriber()
    }

    @objc private func endRecording() {
        guard recordState != .idle else { return }
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
        WhisperEngine.shared.prepare(model: whisperModel, status: { [weak self] message in
            self?.showToast(message)
        }) { [weak self] error in
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

    private func showError(_ error: TranscriberError) {
        refreshSubtitle()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "LiveCaption"
        alert.informativeText = error.message
        if error.settingsAnchor != nil {
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
        } else {
            alert.addButton(withTitle: "好")
        }
        if alert.runModal() == .alertFirstButtonReturn, let anchor = error.settingsAnchor,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
