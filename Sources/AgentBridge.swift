import AppKit
import UniformTypeIdentifiers

/// 把字幕交给你电脑上已经在用的「桌面 AI」（Grok、Claude、ChatGPT……），不需要任何 API Key。
///
/// 字幕文件由 RecordingFile 实时写入（桌面 AI 可以直接读）；
/// 这里负责「一键发送」：把字幕（加上你想问的话）复制到剪贴板，并切换到你选的 AI 应用，按 ⌘V 粘贴即可。
final class AgentBridge {
    enum Request {
        case transcriptOnly
        case summarize
        case actionItems

        var title: String {
            switch self {
            case .transcriptOnly: return "发送字幕（我自己提问）"
            case .summarize: return "发送字幕并请它总结"
            case .actionItems: return "发送字幕并请它提取待办"
            }
        }

        var instruction: String {
            switch self {
            case .transcriptOnly:
                return "下面是我电脑上实时字幕软件记录的内容（语音识别结果，可能有同音错字）。请先读一下，等我提问。"
            case .summarize:
                return "下面是我电脑上实时字幕软件记录的内容（语音识别结果，可能有同音错字）。请总结：主要话题、关键结论、提到的重要数字和时间。"
            case .actionItems:
                return "下面是我电脑上实时字幕软件记录的内容（语音识别结果，可能有同音错字）。请提取待办事项：谁、要做什么、截止时间。没有明确的待办就直接说没有。"
            }
        }
    }

    struct AIApp {
        let name: String
        let url: URL
    }

    private let defaults = UserDefaults.standard

    // MARK: - 一键发送给桌面 AI

    /// 复制「指令 + 字幕」到剪贴板，并切到选中的 AI 应用。返回给用户看的提示。
    func send(_ request: Request, transcript: String, file: URL?) -> String {
        var text = request.instruction
        if let file { text += "\n（完整记录保存在文件：\(file.path)）" }
        text += "\n\n"
        text += transcript.isEmpty ? "（目前还没有字幕）" : transcript

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        if let app = selectedApp {
            NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
            return "字幕已复制，正在打开 \(app.name)，在对话框里按 ⌘V 粘贴即可。"
        }
        return "字幕已复制到剪贴板。请在菜单「AI 应用」里选择你用的桌面 AI，下次会自动帮你切过去。"
    }

    // MARK: - 选择 AI 应用

    /// 在这台 Mac 上找常见的桌面 AI 应用
    func installedApps() -> [AIApp] {
        let names = ["Grok", "Claude", "ChatGPT", "Perplexity", "Gemini", "DeepSeek", "Kimi", "豆包", "元宝"]
        let dirs = [URL(fileURLWithPath: "/Applications"),
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var found: [AIApp] = []
        for name in names {
            for dir in dirs {
                let url = dir.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: url.path) {
                    found.append(AIApp(name: name, url: url))
                    break
                }
            }
        }
        return found
    }

    var selectedApp: AIApp? {
        get {
            if let path = defaults.string(forKey: "aiAppPath"), FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                return AIApp(name: url.deletingPathExtension().lastPathComponent, url: url)
            }
            return installedApps().first   // 没选过就用找到的第一个
        }
        set { defaults.set(newValue?.url.path, forKey: "aiAppPath") }
    }

    /// 让用户自己挑一个 .app
    func chooseOtherApp() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "选择你用的桌面 AI 应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedApp = AIApp(name: url.deletingPathExtension().lastPathComponent, url: url)
        }
    }

}
