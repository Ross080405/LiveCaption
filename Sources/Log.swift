import Foundation

/// 诊断日志：同时写到系统日志（NSLog）和 ~/Library/Logs/LiveCaption.log
enum Log {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LiveCaption.log")
    private static let queue = DispatchQueue(label: "LiveCaption.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        NSLog("[LiveCaption] %@", message)
        let date = Date()
        queue.async {
            let line = "\(formatter.string(from: date)) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }

    /// 启动时调用：日志超过 2MB 就清空重来
    static func startSession() {
        if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? NSNumber,
           size.intValue > 2_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        write("====== LiveCaption \(version) 启动 · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ======")
    }
}
