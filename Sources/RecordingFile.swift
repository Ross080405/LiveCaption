import Foundation

/// 一次「记录」对应一个文件：
/// - 开始时选择：新建文件，或接着写某个已有文件（原内容保留，新字幕追加在后面）
/// - 暂停 → 继续：仍然写入同一个文件，并插入一行「暂停后继续」标记
/// - 结束：文件定稿，下次开始重新选择
/// 另外始终把当前内容同步一份到「最新字幕.md」，方便桌面 AI 用固定路径读取。
final class RecordingFile {
    let folder: URL
    var latestFile: URL { folder.appendingPathComponent("最新字幕.md") }

    /// 当前正在写入的文件；nil 表示没有进行中的记录
    private(set) var url: URL?
    private(set) var isContinuingExisting = false

    private var prefix = ""                           // 新文件的标题，或已有文件的原内容
    private var resumeMarks: [(index: Int, date: Date)] = []
    private var lastWritten = ""
    private var pendingLines: [CaptionLine] = []
    private var pendingPartial = ""
    private var partialStart: Date?                   // 正在说的这一句是什么时候开始的
    private var originalContent: String?              // 接着写入已有文件时，它原来的内容
    /// 正在识别、还没定稿的半句在文件里的标记；定稿后这一行会被正式的句子替换
    static let partialMark = " …（识别中）"
    private var writeScheduled = false

    init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/LiveCaption", isDirectory: true)) {
        self.folder = folder
    }

    var displayName: String { url?.lastPathComponent ?? "" }

    // MARK: - 开始 / 继续 / 结束

    // MARK: - 命名

    /// 命名规则里可以引用的当前情况
    struct NameContext {
        var source = ""
        var language = ""
    }

    static let defaultPattern = "字幕_{date}_{time}"

    /// 命名规则里可用的占位符（给控制台显示）
    static let patternTokens: [(token: String, note: String)] = [
        ("{date}", "日期 2026-11-14"), ("{time}", "时间 12-21-33"),
        ("{year}", "年"), ("{month}", "月"), ("{day}", "日"),
        ("{hour}", "时"), ("{minute}", "分"), ("{weekday}", "星期几"),
        ("{source}", "音频来源"), ("{language}", "识别语言"),
    ]

    /// 把用户输入的名字变成安全的文件名（不含扩展名）；可能返回空字符串
    static func sanitize(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".md", ".txt"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        name = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t")).joined(separator: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// 按命名规则生成文件名（不含扩展名）
    static func expand(_ pattern: String, date: Date, context: NameContext) -> String {
        let numeric = DateFormatter()
        numeric.locale = Locale(identifier: "en_US_POSIX")
        let weekday = DateFormatter()
        weekday.locale = Locale(identifier: "zh_CN")
        weekday.dateFormat = "EEEE"
        func part(_ format: String) -> String { numeric.dateFormat = format; return numeric.string(from: date) }
        let values = [
            "{date}": part("yyyy-MM-dd"), "{time}": part("HH-mm-ss"),
            "{year}": part("yyyy"), "{month}": part("MM"), "{day}": part("dd"),
            "{hour}": part("HH"), "{minute}": part("mm"), "{weekday}": weekday.string(from: date),
            "{source}": context.source, "{language}": context.language,
        ]
        var out = pattern
        for (token, value) in values { out = out.replacingOccurrences(of: token, with: value) }
        let name = sanitize(out)
        return name.isEmpty && pattern != defaultPattern ? expand(defaultPattern, date: date, context: context) : name
    }

    /// 文件夹里不重名的文件地址：重名时加「 (2)」「 (3)」…
    private func uniqueURL(_ base: String, ext: String = "md") -> URL {
        var target = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) || target.lastPathComponent == latestFile.lastPathComponent {
            target = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return target
    }

    /// title 为空时按命名规则自动起名
    func beginNew(title: String? = nil, pattern: String = RecordingFile.defaultPattern, context: NameContext = NameContext()) {
        let now = Date()
        let given = Self.sanitize(title ?? "")
        url = uniqueURL(given.isEmpty ? Self.expand(pattern, date: now, context: context) : given)
        isContinuingExisting = false
        originalContent = nil
        prefix = "# \(given.isEmpty ? "实时字幕记录" : given)\n\n开始时间：\(Self.fullFormatter.string(from: now))\n（语音识别结果，可能有同音错字）\n\n"
        resetState()
    }

    /// 给记录文件改名（正在记录的那个也可以改，之后的字幕写进新名字）。返回新地址。
    @discardableResult
    func rename(_ file: URL, to rawTitle: String) throws -> URL {
        func fail(_ message: String) -> NSError {
            NSError(domain: "LiveCaption", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let base = Self.sanitize(rawTitle)
        guard !base.isEmpty else { throw fail("名字不能为空。") }
        let ext = file.pathExtension.isEmpty ? "md" : file.pathExtension
        let target = folder.appendingPathComponent("\(base).\(ext)")
        if target.lastPathComponent == file.lastPathComponent { return file }
        let onlyCaseDiffers = target.lastPathComponent.lowercased() == file.lastPathComponent.lowercased()
        guard target.lastPathComponent != latestFile.lastPathComponent,
              onlyCaseDiffers || !FileManager.default.fileExists(atPath: target.path) else {
            throw fail("已经有一份叫「\(base)」的记录了。")
        }
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.moveItem(at: file, to: target)
        }
        if url?.lastPathComponent == file.lastPathComponent { url = target }
        return target
    }

    func beginContinuing(_ file: URL) throws {
        let data = try Data(contentsOf: file)
        guard var existing = String(data: data, encoding: .utf8) ?? String(data: data, encoding: Self.gb18030) else {
            throw NSError(domain: "LiveCaption", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法读取这个文件的文字内容（只支持 .md / .txt 文本文件）。"])
        }
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        url = file
        isContinuingExisting = true
        originalContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: Self.gb18030)
        prefix = existing + "\n—— 继续记录：\(Self.fullFormatter.string(from: Date())) ——\n\n"
        resetState()
    }

    /// 暂停后继续时调用：在接下来的字幕前插入标记
    func markResume(atLine index: Int) {
        resumeMarks.append((index, Date()))
    }

    /// 结束本次记录（先写盘）
    func end(lines: [CaptionLine]) {
        flush(lines: lines)
        url = nil
        isContinuingExisting = false
        resetState()
    }

    private func resetState() {
        resumeMarks = []
        lastWritten = ""
        pendingLines = []
        pendingPartial = ""
        partialStart = nil
    }

    // MARK: - 写入

    /// 字幕有变化时调用；0.5 秒内的多次变化合并成一次写入。
    /// partial 是正在识别、还没定稿的半句：也写进文件（带「识别中」标记），
    /// 这样读文件的程序（比如桌面 AI）能跟上正在说的话，不用等一句说完。
    func linesChanged(_ lines: [CaptionLine], partial: String = "") {
        if partial.isEmpty || lines.count != pendingLines.count { partialStart = nil }
        if !partial.isEmpty && partialStart == nil { partialStart = Date() }
        pendingLines = lines
        pendingPartial = partial
        guard url != nil, !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.writeScheduled = false
            self.flush(lines: self.pendingLines, partial: self.pendingPartial)
        }
    }

    func flush(lines: [CaptionLine], partial: String = "") {
        guard let url else { return }
        if lines.isEmpty && partial.isEmpty {
            // 还没说话：不创建 / 不改动文件。
            // 但如果之前写过「识别中」的半句、最后没有定稿，要把文件恢复原样。
            guard !lastWritten.isEmpty else { return }
            if let originalContent {
                try? originalContent.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            lastWritten = ""
            return
        }
        var text = render(lines)
        if !partial.isEmpty {
            text += "[\(Self.timeFormatter.string(from: partialStart ?? Date()))] \(partial)\(Self.partialMark)\n"
        }
        guard text != lastWritten else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            if url.standardizedFileURL != latestFile.standardizedFileURL {
                try text.write(to: latestFile, atomically: true, encoding: .utf8)
            }
            lastWritten = text
        } catch {
            NSLog("LiveCaption: 写入字幕文件失败：\(error.localizedDescription)")
        }
    }

    private func render(_ lines: [CaptionLine]) -> String {
        var out = prefix
        var markIndex = 0
        for line in lines {
            while markIndex < resumeMarks.count && resumeMarks[markIndex].date <= line.start {
                out += "\n—— 暂停后继续：\(Self.timeFormatter.string(from: resumeMarks[markIndex].date)) ——\n\n"
                markIndex += 1
            }
            out += "[\(Self.timeFormatter.string(from: line.start))] \(line.labeledText)\n"
        }
        return out
    }

    // MARK: - 已有文件列表

    /// 文件夹里最近修改的记录文件（用于「继续写入」菜单）
    func recentFiles(limit: Int = 8) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) && $0.lastPathComponent != latestFile.lastPathComponent }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { (url: $0.0, modified: $0.1) }
    }

    // MARK: - 辅助

    static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
}
