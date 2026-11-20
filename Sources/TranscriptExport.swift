import Foundation

struct TranscriptSnapshot {
    let name: String
    let markdown: String
    var plainText: String {
        markdown.replacingOccurrences(of: "(?m)^#{1,6} +", with: "", options: .regularExpression)
    }
    func content(format: String) -> String { format == "txt" ? plainText : markdown }
    func filename(format: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + "." + format
    }
}
