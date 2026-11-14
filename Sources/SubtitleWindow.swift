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
    /// 正在说的那一句：最新的词最浅，越早说出来的越深；一句定稿（写进文档）后整句变成全白。
    /// alphas 是每个字符现在的深浅，targets 是它应该到的深浅，定时器让前者平滑地追上后者。
    private var alphas: [Double] = []
    private var targets: [Double] = []
    private var shownChars: [Character] = []         // 实际显示的文字（太长时是「…」加结尾部分）
    private var shownOffset = 0                      // shownChars 对应 mainText 的起始位置
    private var shownTruncated = false
    private var animationTimer: Timer?
    private var lastTick: CFTimeInterval = 0
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

    /// settled = false 表示 current 是正在识别、还没定稿的半句：结尾的词由浅到深渐变。
    func set(previous: String, current: String, settled: Bool = true) {
        guard previous != prevText || current != mainText || settled != lastSettled else { return }
        lastSettled = settled
        let old = Array(mainText), new = Array(current)
        var same = 0
        while same < min(old.count, new.count), same < alphas.count, old[same] == new[same] { same += 1 }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // 目标深浅：定稿的文字全白；半句里，后面还有几个词就有多深（最新的词最浅）
        var goal = [Double](repeating: 1, count: new.count)
        if !settled && !reduceMotion {
            var depth = 0.0
            for i in stride(from: new.count - 1, through: 0, by: -1) {
                let ch = new[i]
                goal[i] = min(1, 0.22 + depth)
                if ch.isWhitespace { depth += 0.13 }                                                   // 英文等：按词
                else if ch.unicodeScalars.first.map({ $0.value >= 0x2E80 }) == true { depth += 0.06 }   // 中日韩文字：按字
                if depth >= 0.78 { break }
            }
        }
        // 没变的开头保持现在的深浅，新出现（或被改写）的字符从透明开始
        alphas = Array(alphas.prefix(same)) + [Double](repeating: reduceMotion ? 1 : 0, count: new.count - same)
        if reduceMotion { alphas = goal }
        targets = goal
        prevText = previous
        mainText = current
        needsLayout = true
    }
    private var lastSettled = true

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

        applyAppearance()
        if alphas != targets { startAnimation() }
    }

    // MARK: - 由浅到深

    /// 按每个字符现在的深浅重画主字幕
    private func applyAppearance() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString()
        var run = "", runStep = -1

        func flush() {
            guard !run.isEmpty else { return }
            text.append(NSAttributedString(string: run, attributes: [
                .font: mainFont, .paragraphStyle: paragraph,
                .foregroundColor: NSColor.white.withAlphaComponent(Double(runStep) / 40)]))
            run = ""
        }
        for (k, ch) in shownChars.enumerated() {
            let index = shownTruncated ? (k == 0 ? -1 : shownOffset + k - 1) : k    // 开头的「…」始终全白
            let alpha = index >= 0 && index < alphas.count ? alphas[index] : 1
            let step = Int((alpha * 40).rounded())
            if step != runStep { flush(); runStep = step }
            run.append(ch)
        }
        flush()
        mainLabel.attributedStringValue = text
    }

    /// 让每个字符的深浅平滑地靠近目标（约 0.6 秒走完全程）
    private func startAnimation() {
        guard animationTimer == nil else { return }
        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let now = CACurrentMediaTime()
            let step = min(0.1, now - self.lastTick) / 0.6
            self.lastTick = now
            var moving = false
            for i in 0..<min(self.alphas.count, self.targets.count) where self.alphas[i] != self.targets[i] {
                let diff = self.targets[i] - self.alphas[i]
                self.alphas[i] = abs(diff) <= step ? self.targets[i] : self.alphas[i] + (diff > 0 ? step : -step)
                moving = true
            }
            self.applyAppearance()
            if !moving {
                timer.invalidate()
                self.animationTimer = nil
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
