import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 用 ScreenCaptureKit 采集「系统正在播放的声音」（视频、会议、直播等）。
/// 需要「屏幕与系统录音」权限；第一次授权后通常需要重启本应用才生效。
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 在后台线程回调
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "LiveCaption.systemAudio")
    private let videoQueue = DispatchQueue(label: "LiveCaption.systemVideo")

    /// completion 返回 nil 表示成功，否则为错误描述（在后台线程回调）
    func start(completion: @escaping (String?) -> Void) {
        let permissionHint = "\n\n请在「系统设置 → 隐私与安全性 → 屏幕与系统录音」中允许 LiveCaption，然后退出并重新打开本应用。"

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                completion("无法采集系统声音：\(error.localizedDescription)" + permissionHint)
                return
            }
            guard let display = content?.displays.first else {
                completion("没有找到可用的显示器。")
                return
            }

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 1
            // 只要声音；画面压到最小以节省资源
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            config.showsCursor = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
                // 同时挂一个画面输出并丢弃，避免系统日志刷屏
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.videoQueue)
            } catch {
                completion("无法采集系统声音：\(error.localizedDescription)")
                return
            }
            self.stream = stream
            stream.startCapture { error in
                if let error {
                    completion("无法开始采集系统声音：\(error.localizedDescription)" + permissionHint)
                } else {
                    completion(nil)
                }
            }
        }
    }

    func stop() {
        onBuffer = nil
        onError = nil
        stream?.stopCapture { _ in }
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer),
              let buffer = Self.makePCMBuffer(sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("系统声音采集已中断：\(error.localizedDescription)")
    }

    private static func makePCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == OSStatus(0) ? buffer : nil
    }
}
