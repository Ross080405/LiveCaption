import AppKit

/// 悬浮在所有窗口（包括全屏视频）之上的字幕条。
/// 拖动背景可移动，拖动边缘可调整大小；点击它不会抢走其他应用的焦点。
final class SubtitlePanel: NSPanel {
    let subtitleView = SubtitleView()
    private static let autosaveName = "LiveCaptionSubtitleFrame"

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        minSize = NSSize(width: 280, height: 60)
        contentView = subtitleView

        if !setFrameUsingName(Self.autosaveName) {
            setContentSize(NSSize(width: 900, height: subtitleView.preferredHeight))
            moveToDefaultPosition()
        }
        _ = setFrameAutosaveName(Self.autosaveName)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeKey: Bool { true }

    func moveToDefaultPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width = min(frame.width, visible.width - 40)
        setFrame(NSRect(x: visible.midX - width / 2, y: visible.minY + 60,
                        width: width, height: frame.height), display: true)
    }

    /// 字号变化后，按两行字幕的高度重新调整窗口（底边位置不变）
    func fitHeightToFont() {
        var f = frame
        f.size.height = subtitleView.preferredHeight
        setFrame(f, display: true)
    }
}

final class SubtitleView: NSView {
    var fontSize: CGFloat = 30 { didSet { needsLayout = true } }
    var backgroundOpacity: CGFloat = 0.6 { didSet { updateBackground() } }

    private let prevLabel = NSTextField(labelWithString: "")
    private let mainLabel = NSTextField(labelWithString: "")
    private var prevText = ""
    private var mainText = ""
    private let padding: CGFloat = 20
    private let gap: CGFloat = 4
    private static let layoutManager = NSLayoutManager()

    private var mainFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
    private var prevFont: NSFont { .systemFont(ofSize: max(12, round(fontSize * 0.66)), weight: .regular) }

    override var mouseDownCanMoveWindow: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateBackground()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)

        for label in [prevLabel, mainLabel] {
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.usesSingleLineMode = false
            label.cell?.wraps = true
            label.isSelectable = false
            label.drawsBackground = false
            label.shadow = shadow
            addSubview(label)
        }
        mainLabel.textColor = .white
        prevLabel.textColor = NSColor.white.withAlphaComponent(0.6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(previous: String, current: String) {
        guard previous != prevText || current != mainText else { return }
        prevText = previous
        mainText = current
        needsLayout = true
    }

    /// 一行旧字幕 + 两行当前字幕所需的高度
    var preferredHeight: CGFloat {
        ceil(padding * 2 + Self.lineHeight(prevFont) + gap + Self.lineHeight(mainFont) * 2 + 8)
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(backgroundOpacity).cgColor
    }

    override func layout() {
        super.layout()
        let width = max(20, bounds.width - padding * 2)
        let measureWidth = width - 6   // NSTextField 内部有少量边距
        let prevLineH = Self.lineHeight(prevFont)
        let mainLineH = Self.lineHeight(mainFont)

        // 窗口拉高时显示更多行
        let available = bounds.height - padding * 2 - prevLineH - gap - 8
        let mainLines = max(1, Int(available / mainLineH))

        let mainString = Self.fittingTail(mainText, font: mainFont, width: measureWidth, maxLines: mainLines)
        let prevString = Self.fittingTail(prevText, font: prevFont, width: measureWidth, maxLines: 1)

        mainLabel.font = mainFont
        prevLabel.font = prevFont
        mainLabel.stringValue = mainString
        prevLabel.stringValue = prevString

        let mainHeight = Self.textHeight(mainString, font: mainFont, width: measureWidth) + 4
        mainLabel.frame = NSRect(x: padding, y: padding, width: width, height: mainHeight)
        prevLabel.frame = NSRect(x: padding, y: padding + mainHeight + gap, width: width, height: prevLineH + 4)
    }

    // MARK: - 文本测量

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(layoutManager.defaultLineHeight(for: font))
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        if text.isEmpty { return lineHeight(font) }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        return ceil(rect.height)
    }

    /// 字幕太长时只保留结尾部分（最新的话），开头用「…」表示
    private static func fittingTail(_ text: String, font: NSFont, width: CGFloat, maxLines: Int) -> String {
        let limit = lineHeight(font) * CGFloat(maxLines) + 1
        func fits(_ s: String) -> Bool { textHeight(s, font: font, width: width) <= limit }
        if fits(text) { return text }

        let chars = Array(text.suffix(600))
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits("…" + String(chars.suffix(mid))) { lo = mid } else { hi = mid - 1 }
        }
        return "…" + String(chars.suffix(lo))
    }
}
