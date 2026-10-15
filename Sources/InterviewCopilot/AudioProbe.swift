import Foundation

/// Only numerical level statistics; no samples, words, or audio are retained.
struct AudioProbe {
    private(set) var buffers = 0
    private(set) var peak: Float = 0
    var heardSound: Bool { peak >= 0.0003 }
    var summary: String {
        if buffers == 0 { return "尚未收到音频片段" }
        return heardSound ? "已检测到声音" : "已收到片段，尚未检测到声音"
    }
    func transcriptionWarning(elapsed: TimeInterval, hasText: Bool, source: String) -> String? {
        guard elapsed >= 30, heardSound, !hasText else { return nil }
        return "\(source)已有声音，但开始后 30 秒仍无转写文字。请结束本场并回听本地录音，检查收音和识别状态。"
    }
    mutating func observe(_ rms: Float) {
        guard rms.isFinite, rms >= 0 else { return }
        buffers += 1
        peak = max(peak, rms)
    }
}
