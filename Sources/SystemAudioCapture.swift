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
        let granted = CGPreflightScreenCaptureAccess()
        Log.write("屏幕与系统录音权限：\(granted ? "已授权" : "未授权")（应用路径 \(Bundle.main.bundlePath)）")
        let permissionHint = "\n\n请在「系统设置 → 隐私与安全性 → 屏幕与系统录音」中允许 LiveCaption，然后退出并重新打开本应用。"
        /// 采集失败时给用户看的说明：没有权限时给出具体步骤，而不是系统的英文报错
        func explain(_ prefix: String, _ error: Error) -> String {
            Log.write("\(prefix)：\(error)")
            guard !CGPreflightScreenCaptureAccess() else {
                return "\(prefix)：\(error.localizedDescription)" + permissionHint
            }
            CGRequestScreenCaptureAccess()   // 让 LiveCaption 出现在系统设置的列表里（第一次会弹系统提示）
            return """
            这一份 LiveCaption 还没有「屏幕与系统录音」权限，所以采集不到系统声音。

            1. 点「打开系统设置」，在「屏幕与系统录音」里打开 LiveCaption 的开关。
            2. 如果开关已经是开的：那是旧版本留下的授权（应用重新编译或换了位置后，系统会把它当成另一个应用）。选中 LiveCaption 点「−」删掉，再点「+」重新添加现在这一份：\(Bundle.main.bundlePath)
            3. 点「重新打开 LiveCaption」（授权要重启应用才生效）。
            """
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self else { return }
            if let error {
                completion(explain("无法采集系统声音", error))
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
                    completion(explain("无法开始采集系统声音", error))
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
