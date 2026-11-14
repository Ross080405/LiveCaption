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
    /// 影子层：和主字幕同样的文字、稍微偏下并模糊，只显示刚出现的词。
    /// 新词先在这一层以影子出现，再在主字幕上凝成清晰的字。
    private let ghostLabel = NSTextField(labelWithString: "")
    private var births: [CFTimeInterval] = []        // mainText 里每个字符出现的时刻
    private var shownChars: [Character] = []         // 实际显示的文字（太长时是「…」加结尾部分）
    private var shownOffset = 0                      // shownChars 对应 mainText 的起始位置
    private var shownTruncated = false
    private var animationTimer: Timer?
    private static let appearDuration: CFTimeInterval = 0.95
    private static let ghostColor = NSColor(srgbRed: 1.0, green: 0.52, blue: 0.2, alpha: 1)
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

        for label in [prevLabel, ghostLabel, mainLabel] {
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
        ghostLabel.shadow = nil
        ghostLabel.wantsLayer = true
        ghostLabel.layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 3]) {
            ghostLabel.contentFilters = [blur]
        }
        ghostLabel.isHidden = true
        prevLabel.textColor = NSColor.white.withAlphaComponent(0.6)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(previous: String, current: String) {
        guard previous != prevText || current != mainText else { return }
        // 和上一次相同的开头保持不动，后面新出现（或被改写）的字符记下出现时刻，按词依次显形
        let old = Array(mainText), new = Array(current)
        var same = 0
        while same < min(old.count, new.count), same < births.count, old[same] == new[same] { same += 1 }
        let now = CACurrentMediaTime()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var updated = Array(births.prefix(same))
        var delay: CFTimeInterval = 0
        for ch in new[same...] {
            updated.append(reduceMotion ? 0 : now + delay)
            if ch.isWhitespace { delay = min(delay + 0.045, 0.45) }
            else if ch.unicodeScalars.first.map({ $0.value >= 0x2E80 }) == true { delay = min(delay + 0.03, 0.45) }   // 中日韩文字按字
        }
        births = updated
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

        prevLabel.font = prevFont
        prevLabel.stringValue = prevString
        shownChars = Array(mainString)
        shownTruncated = mainString != mainText
        shownOffset = shownTruncated ? mainText.count - (shownChars.count - 1) : 0

        let mainHeight = Self.textHeight(mainString, font: mainFont, width: measureWidth) + 4
        mainLabel.frame = NSRect(x: padding, y: padding, width: width, height: mainHeight)
        prevLabel.frame = NSRect(x: padding, y: padding + mainHeight + gap, width: width, height: prevLineH + 4)
        ghostLabel.frame = mainLabel.frame.offsetBy(dx: 0, dy: -max(4, fontSize * 0.3))

        if applyAppearance() { startAnimation() }
    }

    // MARK: - 新词显形动画

    /// 按每个字符出现了多久，设置主字幕和影子层的透明度。返回是否还有字符在显形中。
    @discardableResult
    private func applyAppearance() -> Bool {
        let now = CACurrentMediaTime()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let main = NSMutableAttributedString(), ghost = NSMutableAttributedString()
        var animating = false
        var run = "", runStep = -1

        func flush() {
            guard !run.isEmpty else { return }
            let p = Double(runStep) / 20
            // 前 40%：只有影子，很快变浓；之后影子慢慢淡去，字渐渐清晰
            let mainAlpha = p < 0.4 ? 0 : pow((p - 0.4) / 0.6, 1.2)
            let ghostAlpha = p >= 1 ? 0 : (p < 0.15 ? p / 0.15 : pow(1 - (p - 0.15) / 0.85, 0.7))
            main.append(NSAttributedString(string: run, attributes: [
                .font: mainFont, .paragraphStyle: paragraph,
                .foregroundColor: NSColor.white.withAlphaComponent(mainAlpha)]))
            let glow = NSShadow()
            glow.shadowColor = Self.ghostColor.withAlphaComponent(ghostAlpha)
            glow.shadowBlurRadius = 20
            glow.shadowOffset = NSSize(width: 0, height: -2)
            ghost.append(NSAttributedString(string: run, attributes: [
                .font: mainFont, .paragraphStyle: paragraph, .shadow: glow,
                .foregroundColor: Self.ghostColor.withAlphaComponent(ghostAlpha)]))
            run = ""
        }

        for (k, ch) in shownChars.enumerated() {
            let index = shownTruncated ? (k == 0 ? -1 : shownOffset + k - 1) : k    // 开头的「…」不参与动画
            var p = 1.0
            if index >= 0, index < births.count {
                p = min(1, max(0, (now - births[index]) / Self.appearDuration))
            }
            if p < 1 { animating = true }
            let step = Int(p * 20)
            if step != runStep { flush(); runStep = step }
            run.append(ch)
        }
        flush()

        mainLabel.attributedStringValue = main
        ghostLabel.attributedStringValue = ghost
        ghostLabel.isHidden = !animating
        return animating
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, self.applyAppearance() else {
                timer.invalidate()
                self?.animationTimer = nil
                return
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
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
