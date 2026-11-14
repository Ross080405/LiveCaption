import AppKit
import WebKit

/// 应用自己的主窗口：里面显示的就是控制台页面（和浏览器里打开 http://localhost 看到的是同一个）。
/// 窗口开着时应用出现在 Dock 和 ⌘Tab 里；关掉后回到只有菜单栏图标。
final class DashboardWindowController: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var loadedURL: URL?

    /// 和页面背景一致，避免加载时闪白
    private static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.051, green: 0.051, blue: 0.055, alpha: 1)
            : NSColor(srgbRed: 0.957, green: 0.957, blue: 0.961, alpha: 1)
    }

    func show(url: URL) {
        if window == nil { build() }
        if loadedURL != url {
            loadedURL = url
            webView?.load(URLRequest(url: url))
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.uiDelegate = self
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "LiveCaption"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.background
        window.minSize = NSSize(width: 460, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("LiveCaptionMainWindow")

        self.window = window
        self.webView = web
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: WKNavigationDelegate

    /// 只在窗口里显示控制台自己的页面；其他链接交给默认浏览器
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.host == loadedURL?.host && url.port == loadedURL?.port {
            decisionHandler(.allow)
        } else {
            if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Log.write("主窗口：页面加载完成")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Log.write("主窗口：页面加载失败：\(error.localizedDescription)")
        loadedURL = nil   // 下次打开窗口时重试
    }

    // MARK: WKUIDelegate

    /// 页面里 target=_blank 的链接：用默认浏览器打开
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// 页面里的 confirm()（比如「移到废纸篓？」）
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let parts = message.components(separatedBy: "\n")
        alert.messageText = parts.first ?? message
        alert.informativeText = parts.dropFirst().joined(separator: "\n")
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        if let window {
            alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
        } else {
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) { _ in completionHandler() } } else { alert.runModal(); completionHandler() }
    }
}
