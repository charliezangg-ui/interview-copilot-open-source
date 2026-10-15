import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    var onAudio: (@Sendable (Bool, Data, Float) -> Void)?
    var onError: (@Sendable (String) -> Void)?
    private var stream: SCStream?
    private var microphone: AudioTrackProcessor?
    private var remote: AudioTrackProcessor?
    private var origin: Double?
    private let queue = DispatchQueue(label: "copilot.audio", qos: .userInitiated)
    @MainActor func start(recordingDirectory: URL? = nil) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AppError.message("需要麦克风权限。请在系统设置中允许后重试。") }
        // Do not repeatedly invoke the system prompt while the stored grant is stale.
        guard CGPreflightScreenCaptureAccess() else {
            throw AppError.message("录屏与系统录音授权未生效。请点击请求授权；若已允许，请完全退出并重新打开。仅系统录音开关不能代替此权限。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw AppError.message("没有可用显示器。") }
        let apps = content.applications.filter { $0.bundleIdentifier.lowercased().contains("wechat") || $0.bundleIdentifier.lowercased().contains("xinwechat") }
        guard !apps.isEmpty else { throw AppError.message("未发现运行中的电脑微信。请打开微信后重试。") }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true; config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true; config.sampleRate = 24000; config.channelCount = 1
        config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.microphone = try AudioTrackProcessor(recordingURL: recordingDirectory?.appendingPathComponent("microphone.wav"))
                    self.remote = try AudioTrackProcessor(recordingURL: recordingDirectory?.appendingPathComponent("wechat.wav"))
                    self.origin = nil
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        self.stream = stream
        try await stream.startCapture()
    }
    @MainActor func stop() async {
        do { try await stream?.stopCapture() }
        catch { onError?("音频采集收尾失败：\(error.localizedDescription)") }
        stream = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                for (mic, processor) in [(true, self.microphone), (false, self.remote)] {
                    do {
                        if let tail = try processor?.finish(), !tail.isEmpty { self.onAudio?(mic, tail, 0) }
                    } catch { self.onError?("本地录音收尾失败：\(error.localizedDescription)") }
                }
                self.microphone = nil; self.remote = nil
                // Main-queue callbacks submitted by this queue are delivered before stop returns.
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?("音频采集中断：\(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription else {
            onError?("收到无效音频片段，当前记录存在缺口。"); return
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer),
                      let processor = type == .microphone ? microphone : remote else {
                    throw AppError.message("无法读取音频片段。")
                }
                let timestamp = sampleBuffer.presentationTimeStamp.seconds
                if origin == nil, timestamp.isFinite { origin = timestamp }
                let (data, rms) = try processor.convert(input, seconds: origin.map { timestamp - $0 })
                if !data.isEmpty { onAudio?(type == .microphone, data, rms) }
            }
        } catch { onError?("音频处理失败，当前记录存在缺口：\(error.localizedDescription)") }
    }
}
