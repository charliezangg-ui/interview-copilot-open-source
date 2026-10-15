import Foundation

private final class DecoderWorker: @unchecked Sendable {
    // Access exclusively on this stream's serial queue.
    var decoder: ZipformerDecoder?
}

@MainActor public final class LocalTranscriptionStream {
    public var onText: ((String, Bool) -> Void)?
    public var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "copilot.local-asr.\(UUID())", qos: .userInitiated)
    private let worker = DecoderWorker()
    private var generation = UUID()
    private var ready = false
    private var failed = false
    private var finishing = false
    private var buffer = Data()
    private var queuedBytes = 0
    private var finishWaiter: CheckedContinuation<Bool, Never>?
    private var finishTimer: Task<Void, Never>?
    public init() {}
    public func start(hotwords: String) async throws {
        guard !ready, !finishing else { throw ASRError.message("本地转写已经启动。") }
        let token = generation
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [worker] in
                let result = Result { worker.decoder = try ZipformerDecoder(hotwords: hotwords) }
                continuation.resume(with: result)
            }
        }
        guard token == generation else { throw CancellationError() }
        ready = true
    }
    public func append(_ data: Data, rms: Float) {
        guard ready, !failed, !finishing else { return }
        // Stop on overload instead of accumulating unbounded audio or silently skipping speech.
        guard queuedBytes + buffer.count + data.count <= 48000 * 8 else {
            fail("本地转写积压超过 8 秒，记录存在缺口。请结束本场并检查系统负载。")
            return
        }
        buffer.append(data)
        if buffer.count >= 4800 { flush() }
    }
    private func flush() {
        guard !buffer.isEmpty else { return }
        let bytes = buffer; buffer.removeAll(keepingCapacity: true); queuedBytes += bytes.count
        let token = generation
        queue.async { [worker, weak self] in
            let result = Result { () throws -> [ASRText] in
                guard let decoder = worker.decoder else { throw ASRError.message("本地转写音轨已关闭。") }
                return try decoder.accept(bytes)
            }
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.queuedBytes -= bytes.count
                self.deliver(result)
            }
        }
    }
    private func deliver(_ result: Result<[ASRText], Error>) {
        guard !failed else { return }
        switch result {
        case .success(let events): for event in events { onText?(event.text, event.isFinal) }
        case .failure(let error): fail(error.localizedDescription)
        }
    }
    private func fail(_ message: String) { guard !failed else { return }; failed = true; ready = false; buffer = Data(); onError?(message) }
    public func finish() async -> Bool {
        guard ready, !failed, !finishing else { stop(); return false }
        finishing = true; flush(); ready = false
        let token = generation
        return await withCheckedContinuation { continuation in
            finishWaiter = continuation
            finishTimer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, token == self.generation else { return }
                self.fail("本地转写收尾超过 30 秒，末尾记录可能不完整。")
                self.stop()
            }
            // This runs after every submitted chunk. Main-queue delivery preserves final event ordering.
            queue.async { [worker, weak self] in
                let result = Result { () throws -> [ASRText] in
                    guard let decoder = worker.decoder else { throw ASRError.message("本地转写音轨已关闭。") }
                    return try decoder.finish()
                }
                worker.decoder = nil
                DispatchQueue.main.async {
                    guard let self, token == self.generation else { return }
                    self.deliver(result); self.finishing = false
                    self.finishTimer?.cancel(); self.finishTimer = nil
                    let waiter = self.finishWaiter; self.finishWaiter = nil
                    waiter?.resume(returning: !self.failed)
                }
            }
        }
    }
    public func stop() {
        generation = UUID(); ready = false; buffer = Data(); queuedBytes = 0
        finishing = false; finishTimer?.cancel(); finishTimer = nil
        let waiter = finishWaiter; finishWaiter = nil; waiter?.resume(returning: false)
        queue.async { [worker] in worker.decoder = nil }
    }
}
