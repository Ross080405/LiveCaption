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
    private var writeScheduled = false

    init() {
        folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/LiveCaption", isDirectory: true)
    }

    var displayName: String { url?.lastPathComponent ?? "" }

    // MARK: - 开始 / 继续 / 结束

    func beginNew() {
        let now = Date()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var target = folder.appendingPathComponent("字幕_\(stamp.string(from: now)).md")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("字幕_\(stamp.string(from: now)) (\(n)).md")
            n += 1
        }
        url = target
        isContinuingExisting = false
        prefix = "# 实时字幕记录\n\n开始时间：\(Self.fullFormatter.string(from: now))\n（语音识别结果，可能有同音错字）\n\n"
        resetState()
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
    }

    // MARK: - 写入

    /// 字幕有变化时调用；1 秒内的多次变化合并成一次写入
    func linesChanged(_ lines: [CaptionLine]) {
        pendingLines = lines
        guard url != nil, !writeScheduled else { return }
        writeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.writeScheduled = false
            self.flush(lines: self.pendingLines)
        }
    }

    func flush(lines: [CaptionLine]) {
        guard let url, !lines.isEmpty else { return }   // 还没说话就不创建 / 不改动文件
        let text = render(lines)
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
        for (i, line) in lines.enumerated() {
            while markIndex < resumeMarks.count && resumeMarks[markIndex].index <= i {
                out += "\n—— 暂停后继续：\(Self.timeFormatter.string(from: resumeMarks[markIndex].date)) ——\n\n"
                markIndex += 1
            }
            out += "[\(Self.timeFormatter.string(from: line.start))] \(line.text)\n"
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
