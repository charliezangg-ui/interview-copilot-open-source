import Foundation
import AppKit
import PDFKit
import CopilotCore
import HireIntegration
import CodexIntegration
import LocalASR
import ScreenCaptureKit
import AVFoundation

struct SessionArchive: Codable {
    var id: UUID; var date: Date; var mode: String; var rubric: String; var material: String
    var turns: [Utterance]; var frozen: FrozenReview?; var human: String; var comparison: Comparison?; var hasGap: Bool
    var hireMaterial: HireMaterial? = nil
    var asrHotwords: String? = nil
    var comparedHuman: String? = nil
    var originalTexts: [String: String]? = nil
    var cleanupDraft: [TranscriptEdit]? = nil
    var recordingPath: String? = nil
    var previousReviews: [FrozenReview]? = nil
    var cleanupProgress: CleanupProgress? = nil
}
struct SavedSession: Identifiable {
    let url: URL
    let archive: SessionArchive
    var id: UUID { archive.id }
}
@MainActor final class SessionStore: ObservableObject {
    @Published var material = ""
    @Published private(set) var importingMaterial = false
    @Published var hireURL = ""
    @Published var hireCandidate: HireCandidate?
    @Published var selectedResumeID = ""
    @Published var hireMaterial: HireMaterial?
    @Published var importMessage = ""
    @Published var canUndoImport = false
    private var previousMaterial: (String, HireMaterial?)?
    // Preserve legacy archive data without applying retired editable role rules to new reviews.
    private var archivedRubric = Prompts.rubric
    @Published var turns: [Utterance] = []
    @Published var partialHR = ""
    @Published var partialCandidate = ""
    @Published var human = "" {
        didSet {
            if human != oldValue {
                judgmentSaveStatus = "有未保存的修改"
                if comparison != nil { status = "判断已修改 · 请重新提交独立对照" }
                comparison = nil; comparedHuman = nil
            }
        }
    }
    @Published private(set) var judgmentSaveStatus = ""
    @Published var frozen: FrozenReview?
    @Published var comparison: Comparison?
    private var comparedHuman: String?
    @Published var status = "准备就绪"
    @Published var error = ""
    @Published var active = false
    @Published var busy = false
    @Published var ending = false
    @Published var revealed = false
    @Published var mode = "未开始"
    @Published var microphoneLevel: Float = 0
    @Published var candidateLevel: Float = 0
    @Published private(set) var checkingAudio = false
    @Published private(set) var microphoneProbe = AudioProbe()
    @Published private(set) var candidateProbe = AudioProbe()
    @Published private(set) var hasAudioCheck = false
    @Published var codexReady = false
    @Published var codexStatus = "未连接 Codex"
    @Published private(set) var codexExecutablePath = UserDefaults.standard.string(forKey: CodexExecutable.preferenceKey) ?? ""
    private let codex = CodexClient()
    @Published var asrHotwords = Hotwords.defaults
    @Published var localModelReady = LocalModelStore.isInstalled()
    @Published var localModelStatus = LocalModelStore.isInstalled() ? "中英本地转写模型已安装" : "尚未下载本地转写模型（约 199 MB）"
    @Published var allowCloud = false
    @Published var informed = false
    @Published private(set) var originalTexts: [String: String] = [:]
    @Published private(set) var cleanupDraft: [TranscriptEdit] = []
    @Published private(set) var cleanupStatus = ""
    @Published private(set) var cleanupProgress: CleanupProgress?
    @Published private(set) var cleanupRunning = false
    @Published private(set) var cleanupStartedAt: Date?
    private var cleanupTask: Task<Void, Never>?
    @Published private(set) var recordingPath: String?
    @Published private(set) var playingTrack: Speaker?
    @Published private(set) var audioWarning = ""
    private var previousReviews: [FrozenReview] = []
    private var player: AVAudioPlayer?
    private var audioHealthTask: Task<Void, Never>?
    private var lastMicrophone = Date()
    private var lastRemote = Date()
    private var hrPhraseStart: Double?
    private var candidatePhraseStart: Double?
    @Published var archivePath = ""
    private var sessionID = UUID()
    private var startedAt = Date()
    private var capture: AudioCapture?
    private var hrStream: LocalTranscriptionStream?
    private var candidateStream: LocalTranscriptionStream?
    private var gap = false
    private let archiveDirectory: URL?
    private let requestJSON: ((String) async throws -> Data)?
    private let connectForTesting: (() async throws -> String)?
    var canCloud: Bool { allowCloud && codexReady }
    var canEditMaterial: Bool { !busy && !ending && !importingMaterial && frozen == nil }
    var reviewBlocker: String? {
        if active || ending { return "请先结束面试，等待转写收尾后提交。" }
        if importingMaterial { return "候选人材料正在导入，完成后即可提交。" }
        if busy { return "正在处理，请等待当前操作完成。" }
        if !cleanupDraft.isEmpty { return "请先确认或放弃文字校对草稿，再提交判断。" }
        if turns.isEmpty { return "当前记录没有面试发言。补充这场的实际问答后才能独立复核；保存判断不会自动生成面试记录。" }
        if gap { return "本场转写存在缺口，暂不能生成完整初评；判断仍可保存。" }
        if human.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请先写下你的判断。" }
        return nil
    }
    var canChooseReviewTranscript: Bool {
        !active && !ending && !busy && !importingMaterial && cleanupDraft.isEmpty && turns.isEmpty
    }
    var canTranscribe: Bool { localModelReady }
    var canCleanTranscript: Bool { !active && !ending && !busy && !turns.isEmpty && cleanupDraft.isEmpty }
    var canResumeCleanup: Bool {
        guard let progress = cleanupProgress else { return false }
        return progress.revision == TranscriptCleanup.revision && progress.source == turns && progress.hotwords == Hotwords.normalize(asrHotwords) && progress.completedBatches > 0
    }

    init(archiveDirectory: URL? = nil, requestJSON: ((String) async throws -> Data)? = nil, connectForTesting: (() async throws -> String)? = nil) {
        self.archiveDirectory = archiveDirectory
        self.requestJSON = requestJSON
        self.connectForTesting = connectForTesting
        codex.onProgress = { [weak self] text in
            guard let self else { return }
            self.codexStatus = text
            if self.cleanupRunning, let progress = self.cleanupProgress {
                let total = TranscriptCleanup.batches(progress.source).count
                self.cleanupStatus = "校对第 \(min(progress.completedBatches + 1, total)) / \(total) 批 · \(text)"
            }
        }
    }
    func chooseCodexExecutable() {
        guard !active, !busy, !ending else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 可执行文件"
        panel.message = "选择 codex 文件。可按 Command-Shift-G 输入终端中 command -v codex 显示的路径。"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard CodexExecutable.isExecutable(url.path) else {
            error = "所选文件不可执行，请选择已安装的 codex 文件。"; return
        }
        setCodexExecutable(url.path)
    }
    func setCodexExecutable(_ path: String) {
        guard !active, !busy, !ending else { return }
        codex.stop()
        codexReady = false
        codexExecutablePath = path
        if path.isEmpty { UserDefaults.standard.removeObject(forKey: CodexExecutable.preferenceKey) }
        else { UserDefaults.standard.set(path, forKey: CodexExecutable.preferenceKey) }
        codexStatus = "Codex 路径已更新 · 请检测连接"
        error = ""
    }
    func connectCodex() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            try await withTextRequestRetry(stage: "正在连接本机 Codex") { try await self.ensureCodexConnection() }
            error = ""
        }
        catch { codexReady = false; self.error = TextRequestFailures.description(error); codexStatus = "连接失败，可重试" }
    }
    private func ensureCodexConnection() async throws {
        guard !codexReady else { return }
        do {
            if let connectForTesting { codexStatus = try await connectForTesting() }
            else { codexStatus = try await codex.connect() }
            try Task.checkCancellation()
            codexReady = true
        } catch { codexReady = false; throw error }
    }
    private func withTextRequestRetry<T>(stage: String, operation: () async throws -> T) async throws -> T {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                guard attempt == 0, TextRequestFailures.isTransient(error) else { throw error }
                codex.stop("连接暂时失败，准备重试"); codexReady = false
                let message = "\(stage) · 连接暂时失败，正在自动重试（1 / 1）…"
                if cleanupRunning { cleanupStatus = message } else { status = message }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw AppError.message("文本处理未完成。")
    }
    func stopCodex() { codex.stop(); codexReady = false; codexStatus = "已停止，可重新连接" }
    private func requestAI<T: Decodable>(_ prompt: String, as type: T.Type, system: String = Prompts.system) async throws -> T {
        try await withTextRequestRetry(stage: status) {
            try await self.ensureCodexConnection()
            if let requestJSON = self.requestJSON { return try JSONDecoder().decode(type, from: await requestJSON(prompt)) }
            // Transport reuse shares no conversation: run always starts a fresh ephemeral thread.
            // Base instructions, disabled Memory/tools and the supplied prompt define its whole context.
            let client = self.codex
            let instructions = system + "\n只使用本次提供的数据。禁止调用工具或读取外部文件、Memory、会话。返回外层 JSON 的 answer 字段，字段内容为用户要求的完整 JSON 字符串，不附加 Markdown 或引用脚注。"
            let value = try await withTaskCancellationHandler {
                try await client.run(prompt, lane: .assessment, instructions: instructions, structured: true)
            } onCancel: { Task { @MainActor in client.stop("已取消文本处理") } }
            try Task.checkCancellation()
            return try JSONDecoder().decode(type, from: Data(value.utf8))
        }
    }
    func prepareLocalModel() async {
        guard !active, !busy, !ending else { return }
        busy = true; error = ""; defer { busy = false }
        do {
            try await LocalModelStore.install { [weak self] message in Task { @MainActor in self?.localModelStatus = message } }
            localModelReady = true; localModelStatus = "中英本地转写模型已校验就绪"
        } catch { localModelReady = LocalModelStore.isInstalled(); self.error = error.localizedDescription }
    }
    // Explicit user action only. Opening Settings must not silently request access too.
    func requestScreenAuthorization(request: () async throws -> Void = {
        _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }) async {
        guard !busy, !active, !ending else { return }
        busy = true
        defer { busy = false }
        status = "等待系统授权结果…"
        do {
            try await request()
            error = ""
            status = "系统录音访问检查通过 · 请点击检测音频确认两路输入"
        } catch {
            self.error = "录屏与系统录音授权未生效：\(error.localizedDescription)"
            status = "请在系统设置上方的录屏与系统录音列表允许 InterviewCopilot，再完全退出并重新打开"
        }
    }
    @discardableResult func reset() -> Bool {
        guard !active, !busy, !ending, !importingMaterial, save() else { return false }
        clearSession()
        return true
    }
    private func clearSession() {
        audioHealthTask?.cancel(); stopPlayback()
        hasAudioCheck = false; checkingAudio = false
        microphoneProbe = AudioProbe(); candidateProbe = AudioProbe()
        turns = []; frozen = nil; comparison = nil; human = ""; revealed = false
        judgmentSaveStatus = ""
        partialHR = ""; partialCandidate = ""; status = "准备就绪"; error = ""; mode = "未开始"
        asrHotwords = Hotwords.defaults
        originalTexts = [:]; cleanupDraft = []; cleanupStatus = ""; recordingPath = nil; previousReviews = []
        cleanupProgress = nil; cleanupStartedAt = nil
        audioWarning = ""; hrPhraseStart = nil; candidatePhraseStart = nil
        archivedRubric = Prompts.rubric
        sessionID = UUID(); startedAt = Date(); gap = false; material = ""; informed = false; archivePath = ""
        hireURL = ""; hireCandidate = nil; selectedResumeID = ""; hireMaterial = nil; importMessage = ""; previousMaterial = nil; canUndoImport = false
    }
    func add(_ turn: Utterance) {
        let index = turns.firstIndex(where: { $0.seconds > turn.seconds }) ?? turns.endIndex
        turns.insert(turn, at: index); save()
    }

    func generateCleanup() async {
        guard canCleanTranscript, allowCloud else { return }
        busy = true; cleanupRunning = true; cleanupStartedAt = Date(); error = ""
        let task = Task<Void, Never> { [weak self] in await self?.performCleanup() }
        cleanupTask = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        cleanupTask = nil; cleanupRunning = false; busy = false
    }

    func cancelCleanup() {
        guard cleanupRunning else { return }
        cleanupTask?.cancel()
        codex.stop("已停止文字校对"); codexReady = false
    }

    private func performCleanup() async {
        let snapshot = turns
        let terms = Hotwords.normalize(asrHotwords)
        let batches = TranscriptCleanup.batches(snapshot)
        let completed = cleanupProgress?.completedBatches ?? 0
        let cachedEditsValid = (try? TranscriptCleanup.validate(cleanupProgress?.changes ?? [], in: batches.prefix(max(0, completed)).flatMap { $0 })) != nil
        if cleanupProgress?.revision != TranscriptCleanup.revision || cleanupProgress?.source != snapshot || cleanupProgress?.hotwords != terms || !(0...batches.count).contains(completed) || !cachedEditsValid {
            cleanupProgress = CleanupProgress(source: snapshot, hotwords: terms)
        }
        do {
            guard save() else { throw AppError.message("校对进度无法保存，未发送文本。") }
            for index in (cleanupProgress?.completedBatches ?? 0)..<batches.count {
                try Task.checkCancellation()
                let batch = batches[index]
                cleanupStatus = "正在校对第 \(index + 1) / \(batches.count) 批 · 已完成 \(index) 批"
                let before = index > 0 ? Array(batches[index - 1].suffix(2)) : []
                let after = index + 1 < batches.count ? Array(batches[index + 1].prefix(2)) : []
                let result = try await requestCleanupBatch(batch, hotwords: terms, context: ["before": before, "after": after])
                try Task.checkCancellation()
                try TranscriptCleanup.validate(result.changes, in: batch)
                guard turns == snapshot else { throw AppError.message("正文已变化，请重新校对。") }
                cleanupProgress?.changes += result.changes.filter { edit in batch.first(where: { $0.id == edit.id })?.text != edit.text }
                cleanupProgress?.completedBatches = index + 1
                guard save() else { throw AppError.message("校对进度写入失败，请重试保存；已完成结果仍在当前窗口。") }
            }
            try Task.checkCancellation()
            guard turns == snapshot else { throw AppError.message("正文已变化，请重新校对。") }
            let completed = cleanupProgress
            cleanupDraft = completed?.changes ?? []; cleanupProgress = nil
            guard save() else {
                cleanupProgress = completed; cleanupDraft = []
                throw AppError.message("校对草稿保存失败，请重试；已完成结果仍在当前窗口。")
            }
            cleanupStatus = cleanupDraft.isEmpty ? "未发现需要修改的文字" : "\(cleanupDraft.count) 段待确认 · 尚未改动正文"
        } catch {
            let completed = cleanupProgress?.completedBatches ?? 0
            if Task.isCancelled || error is CancellationError {
                self.error = ""; cleanupStatus = "已停止 · 已完成 \(completed) / \(batches.count) 批，可继续；正文未修改"
            } else {
                self.error = "文字校对失败：\(TextRequestFailures.description(error))"
                cleanupStatus = "已完成 \(completed) / \(batches.count) 批，重试从未完成处继续；正文未修改"
            }
        }
    }

    private func requestCleanupBatch(_ batch: [Utterance], hotwords: String, context: [String: [Utterance]]) async throws -> TranscriptCleanupResult {
        let prompt = try TranscriptCleanup.prompt(turns: batch, hotwords: hotwords, context: context)
        return try await withTextRequestRetry(stage: cleanupStatus) {
            if !self.codexReady { self.cleanupStatus = "正在连接 Codex…"; try await self.ensureCodexConnection() }
            if let requestJSON = self.requestJSON { return try TranscriptCleanup.decode(await requestJSON(prompt), in: batch) }
            let instructions = TranscriptCleanup.instructions + "\n只使用本批数据。返回外层 JSON 的 answer 字段，内容为完整 JSON 字符串。"
            let answer = try await self.codex.run(prompt, lane: .assessment, instructions: instructions, structured: true)
            try Task.checkCancellation()
            return try TranscriptCleanup.decode(Data(answer.utf8), in: batch)
        }
    }

    func confirmAndGenerateCleanup() async {
        guard canCleanTranscript else { return }
        let previous = allowCloud; allowCloud = true
        defer { allowCloud = previous }
        await generateCleanup()
    }

    @discardableResult func applyTranscriptEdits(_ edits: [TranscriptEdit]) -> Bool {
        guard !active, !ending, !busy, !edits.isEmpty else { return false }
        do {
            try TranscriptCleanup.validate(edits, in: turns)
            // Keep original ASR and previous assessments for audit; never rewrite a fixed assessment.
            let oldTurns = turns, oldOriginals = originalTexts, oldFrozen = frozen
            let oldComparison = comparison, oldCompared = comparedHuman, oldRevealed = revealed
            let oldReviews = previousReviews, oldDraft = cleanupDraft, oldProgress = cleanupProgress
            for edit in edits {
                guard let index = turns.firstIndex(where: { $0.id == edit.id }) else { continue }
                if originalTexts[edit.id] == nil { originalTexts[edit.id] = turns[index].text }
                turns[index].text = edit.text
            }
            if let frozen { previousReviews.append(frozen) }
            frozen = nil; comparison = nil; comparedHuman = nil; revealed = false; cleanupDraft = []; cleanupProgress = nil
            guard save() else {
                turns = oldTurns; originalTexts = oldOriginals; frozen = oldFrozen; comparison = oldComparison
                comparedHuman = oldCompared; revealed = oldRevealed; previousReviews = oldReviews; cleanupDraft = oldDraft; cleanupProgress = oldProgress
                return false
            }
            cleanupStatus = "正文已更新"
            status = "文字已校对并保存 · 提交判断时使用新正文重新复核"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func keepOriginalText(_ id: String) {
        guard !busy else { return }
        cleanupDraft.removeAll { $0.id == id }
        cleanupStatus = cleanupDraft.isEmpty ? "已保留原文，没有待应用的修改" : "\(cleanupDraft.count) 段待确认"
        save()
    }

    func discardCleanup() {
        guard !busy else { return }
        cleanupDraft = []; cleanupProgress = nil; cleanupStatus = "已放弃校对草稿，正文未修改"; save()
    }

    func stopPlayback() { player?.stop(); player = nil; playingTrack = nil }
    func playRecording(_ speaker: Speaker) {
        guard !active, !ending, let recordingPath else { return }
        if playingTrack == speaker, player?.isPlaying == true { stopPlayback(); return }
        stopPlayback()
        do {
            let file = URL(fileURLWithPath: recordingPath).appendingPathComponent(speaker == .interviewer ? "microphone.wav" : "wechat.wav")
            let audio = try AVAudioPlayer(contentsOf: file)
            guard audio.play() else { throw AppError.message("录音无法播放。") }
            player = audio; playingTrack = speaker
        } catch { self.error = "回听失败：\(error.localizedDescription)" }
    }

    func startLive() async {
        guard !active, !busy, !ending, !importingMaterial, turns.isEmpty, canTranscribe, informed else { return }
        busy = true; error = ""; status = "加载本地双路转写模型…"; mode = "电脑微信 · 本地 Zipformer 转写"
        let hr = LocalTranscriptionStream(), candidate = LocalTranscriptionStream()
        hrStream = hr; candidateStream = candidate
        for (client, speaker) in [(hr, Speaker.interviewer), (candidate, Speaker.candidate)] {
            client.onText = { [weak self] text, final in
                guard let self else { return }
                let now = Date().timeIntervalSince(self.startedAt)
                if !text.isEmpty {
                    if speaker == .interviewer && self.hrPhraseStart == nil { self.hrPhraseStart = now }
                    if speaker == .candidate && self.candidatePhraseStart == nil { self.candidatePhraseStart = now }
                }
                if final {
                    let seconds = (speaker == .interviewer ? self.hrPhraseStart : self.candidatePhraseStart) ?? now
                    if speaker == .interviewer { self.hrPhraseStart = nil } else { self.candidatePhraseStart = nil }
                    if speaker == .interviewer { self.partialHR = "" } else { self.partialCandidate = "" }
                    if !text.isEmpty { self.add(.init(speaker: speaker, text: text, seconds: seconds)) }
                } else if speaker == .interviewer { self.partialHR = text } else { self.partialCandidate = text }
            }
            client.onError = { [weak self] message in self?.error = message; self?.gap = true }
        }
        do {
            try await hr.start(hotwords: asrHotwords)
            try await candidate.start(hotwords: asrHotwords)
            let dir = try archiveDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InterviewCopilot/Sessions", isDirectory: true)
            let recordings = dir.appendingPathComponent(sessionID.uuidString + "-audio", isDirectory: true)
            try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            recordingPath = recordings.path
            // Persist the audio location even if the app exits before the first final subtitle.
            guard save() else { throw AppError.message("无法保存本场录音位置，未开始采集。") }
            microphoneProbe = AudioProbe(); candidateProbe = AudioProbe(); audioWarning = ""
            let capture = AudioCapture(); self.capture = capture
            capture.onAudio = { [weak self] mic, data, rms in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if mic {
                        self.lastMicrophone = Date(); self.microphoneProbe.observe(rms)
                        self.microphoneLevel = rms; self.hrStream?.append(data, rms: rms)
                    } else {
                        self.lastRemote = Date(); self.candidateProbe.observe(rms)
                        self.candidateLevel = rms; self.candidateStream?.append(data, rms: rms)
                    }
                }
            }
            capture.onError = { [weak self] message in DispatchQueue.main.async { self?.error = message; self?.gap = true } }
            startedAt = Date()
            try await capture.start(recordingDirectory: recordings)
            active = true; lastMicrophone = Date(); lastRemote = Date()
            status = "正在本地录音并转写 · 请确认两路电平均有变化"
            audioHealthTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                    guard let self, self.active else { return }
                    var warnings: [String] = []
                    if Date().timeIntervalSince(self.lastMicrophone) > 5 { warnings.append("麦克风未收到音频片段，请检查输入设备") }
                    else if !self.microphoneProbe.heardSound { warnings.append("麦克风尚未检测到人声电平，请说话确认收音") }
                    if Date().timeIntervalSince(self.lastRemote) > 5 { warnings.append("微信未收到音频片段，请检查通话和输出设备") }
                    else if !self.candidateProbe.heardSound { warnings.append("微信尚未检测到声音，请让对方说话确认") }
                    let elapsed = Date().timeIntervalSince(self.startedAt)
                    if let warning = self.microphoneProbe.transcriptionWarning(elapsed: elapsed, hasText: !self.partialHR.isEmpty || self.turns.contains { $0.speaker == .interviewer }, source: "麦克风") { warnings.append(warning) }
                    if let warning = self.candidateProbe.transcriptionWarning(elapsed: elapsed, hasText: !self.partialCandidate.isEmpty || self.turns.contains { $0.speaker == .candidate }, source: "微信") { warnings.append(warning) }
                    self.audioWarning = warnings.joined(separator: "；")
                }
            }
        } catch {
            self.error = error.localizedDescription; hr.stop(); candidate.stop(); await capture?.stop(); capture = nil; status = "接入未成功"
        }
        busy = false
    }
    func startAudioCheck() async {
        guard !active, !busy, !ending, !importingMaterial, turns.isEmpty, informed else { return }
        busy = true; error = ""; mode = "本地音频检测 · 不上传不录盘"
        microphoneProbe = AudioProbe(); candidateProbe = AudioProbe()
        checkingAudio = true; hasAudioCheck = true
        let capture = AudioCapture(); self.capture = capture
        capture.onAudio = { [weak self] mic, _, rms in
            DispatchQueue.main.async {
                guard let self, self.checkingAudio else { return }
                if mic { self.microphoneLevel = rms; self.microphoneProbe.observe(rms) }
                else { self.candidateLevel = rms; self.candidateProbe.observe(rms) }
            }
        }
        capture.onError = { [weak self] message in DispatchQueue.main.async { self?.error = message } }
        do { try await capture.start(); active = true; status = "仅检测两路电平，不上传音频，不保存录音" }
        catch { self.error = error.localizedDescription; checkingAudio = false; await capture.stop(); self.capture = nil; status = "音频检测未启动" }
        busy = false
    }
    func finish() async {
        guard active, !ending else { return }
        ending = true; active = false; audioHealthTask?.cancel(); stopPlayback()
        let wasAudioCheck = checkingAudio
        checkingAudio = false
        await capture?.stop(); capture = nil
        if wasAudioCheck {
            microphoneLevel = 0; candidateLevel = 0; ending = false
            status = "检测已停止 · 麦克风：\(microphoneProbe.summary)；微信：\(candidateProbe.summary)"
            return
        }
        status = "等待最后一段转写…"
        if let hr = hrStream, let candidate = candidateStream {
            if !microphoneProbe.heardSound || !candidateProbe.heardSound {
                gap = true
                error = "本场至少一路未检测到声音，记录可能不完整。请回听本地录音并检查设备；文字校对不能补回未采集音频。"
            }
            async let a = hr.finish(); async let b = candidate.finish()
            let results = await (a, b)
            if !results.0 || !results.1 { gap = true; error = "末尾转写未完成，存在记录缺口。请先核对原话，当前禁止生成完整初评。" }
        }
        hrStream = nil; candidateStream = nil; microphoneLevel = 0; candidateLevel = 0
        if turns.isEmpty {
            gap = true
            error = "本场没有识别出面试文字，无法独立复核。请回听本地录音，或补充实际面试问答；保存判断不会补齐转写。"
        }
        ending = false; save()
        if gap { status = "记录存在缺口 · 未生成初评"; return }
        if importingMaterial { status = "面试已结束 · 材料导入完成后可提交判断"; return }
        status = "记录已保存 · 可先校对文字、回听录音，再提交判断"
    }
    func freeze() async {
        guard !active, !ending, !busy, !importingMaterial, !turns.isEmpty, cleanupDraft.isEmpty, canCloud, frozen == nil, !gap else { return }
        busy = true; status = "正在固定独立初评（尚未读取你的评价）"
        defer { busy = false }
        let snapshot = turns, standards = Prompts.effectiveRubric(Prompts.rubric), source = material
        do {
            let assessment = try await requestAI(Prompts.independent(rubric: standards, material: source, turns: snapshot), as: Assessment.self)
            try Evidence.validate(assessment, in: snapshot)
            frozen = FrozenReview(rubric: standards, material: source, transcript: snapshot, assessment: assessment)
            status = "独立初评已固定并隐藏 · 请先写下你的判断"; save()
        } catch { self.error = "独立初评失败：\(TextRequestFailures.description(error))"; status = "尚未生成有效初评 · 本地判断已保存，可重试" }
    }
    // Called only by the explicit confirmation button. Permission is scoped to this
    // submission; it must not enable automatic cloud analysis in later interviews.
    func confirmAndSubmitJudgment() async -> Bool {
        if let blocker = reviewBlocker { error = blocker; return false }
        guard save(announce: true) else { return false }
        error = ""
        if !codexReady {
            status = "正在连接本机 Codex…"
            await connectCodex()
            guard codexReady else { status = "判断已保存 · Codex 连接失败，可重试"; return false }
        }
        let previousConsent = allowCloud
        allowCloud = true
        defer { allowCloud = previousConsent }
        await submitJudgment()
        return error.isEmpty && comparison != nil
    }
    func submitJudgment() async {
        if let blocker = reviewBlocker { error = blocker; return }
        guard save(announce: true) else { return }
        guard canCloud else { status = "判断已保存 · 请连接本机 Codex 并允许文本分析后提交"; return }
        error = ""
        if frozen == nil { await freeze() }
        guard frozen != nil, save() else { return }
        await compare()
    }
    func compare() async {
        guard let frozen, canCloud, !active, !ending, !busy, !importingMaterial, !human.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; status = "用候选人回答检验你的判断…"; defer { busy = false }
        let opinion = human
        do {
            let result = try await requestAI(Prompts.comparison(frozen: frozen, human: opinion), as: Comparison.self)
            for item in result.items {
                guard ["有证据支持", "存在相反证据", "证据不足"].contains(item.status) else { throw EvidenceError.invalidStatus }
                try Evidence.validate(item.evidenceIDs, in: frozen.transcript)
                if item.status != "证据不足" && item.evidenceIDs.isEmpty { throw EvidenceError.invalidReference }
            }
            guard human == opinion else { status = "判断已修改 · 请重新提交独立对照"; return }
            comparison = result; comparedHuman = opinion; revealed = true; status = "对照完成 · 初评保持原样，决定由你作出"; save()
        } catch { self.error = "对照失败：\(TextRequestFailures.description(error))"; status = "独立初评已保留 · 重试只继续对照" }
    }
    private func presentFilePanel(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    func importMaterial() {
        guard canEditMaterial else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText, .pdf]; panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        let requestSession = sessionID
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, self.sessionID == requestSession else { return }
            self.importMaterial(from: url)
        }
    }
    func importMaterial(from url: URL) {
        guard canEditMaterial else { return }
        do {
            let text: String
            if url.pathExtension.lowercased() == "pdf" {
                guard let extracted = PDFDocument(url: url)?.string, !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("PDF 没有可提取的文字；Demo 暂不支持扫描件 OCR，请粘贴文字。") }
                text = extracted
            } else { text = try String(contentsOf: url, encoding: .utf8) }
            guard text.count <= 80000 else { throw AppError.message("材料过长，请先提取与岗位相关的部分。") }
            previousMaterial = (material, hireMaterial); canUndoImport = true
            material = text; hireMaterial = nil; status = "已导入材料，仅保存在本机；启用云端分析后才发送"; save()
        } catch { self.error = error.localizedDescription }
    }
    func importHireLink(
        lookup: (String) async throws -> HireCandidate = { try await HireImporter().lookup($0) },
        load: (HireCandidate, String) async throws -> ImportedResume = { try await HireImporter().load($0, attachmentID: $1) }
    ) async {
        guard canEditMaterial else { return }
        importingMaterial = true; error = ""; importMessage = "正在获取飞书招聘简历…"; defer { importingMaterial = false }
        do {
            let parsed = try HireLink(hireURL)
            if let current = hireMaterial, current.link.talentID != parsed.talentID { throw HireError.message("本场已有另一位候选人的材料。请先新建面试，避免混入不同候选人。") }
            let candidate = try await lookup(hireURL)
            guard candidate.link.talentID == parsed.talentID, let resume = candidate.resumes.first else { throw HireError.message("候选人身份不匹配或没有可导入的简历。") }
            hireCandidate = candidate; selectedResumeID = resume.id
            hireURL = candidate.link.canonicalURL
            importMessage = "已找到 \(candidate.resumes.count) 份简历，正在下载并解析…"
            let imported = try await load(candidate, selectedResumeID)
            applyHireImport(imported)
        } catch { self.error = error.localizedDescription; importMessage = "导入未完成，原有材料保持不变" }
    }
    func importSelectedResume() async {
        guard let candidate = hireCandidate, canEditMaterial else { return }
        importingMaterial = true; error = ""; importMessage = "正在解析所选简历…"; defer { importingMaterial = false }
        do { let imported = try await HireImporter().load(candidate, attachmentID: selectedResumeID); applyHireImport(imported) }
        catch { self.error = error.localizedDescription; importMessage = "导入未完成，原有材料保持不变" }
    }
    private func applyHireImport(_ imported: ImportedResume) {
        previousMaterial = (material, hireMaterial); canUndoImport = true
        material = "来源：飞书招聘简历附件（候选人材料，未经外部核实）\n候选人：\(imported.source.candidateName)\n文件：\(imported.source.fileName)\n\n" + imported.text
        hireMaterial = imported.source
        importMessage = "已导入 · \(imported.pages) 页 · \(imported.text.count) 字符" + (imported.source.usedOCR ? " · 含本地 OCR，请核对数字与术语" : "")
        status = "飞书简历已加入本场材料 · 附件副本保存在本机"; save()
    }
    func undoImport() {
        guard let previousMaterial, canEditMaterial else { return }
        material = previousMaterial.0; hireMaterial = previousMaterial.1; self.previousMaterial = nil; canUndoImport = false
        importMessage = "已撤销正文替换；下载文件仍保留在本机"; save()
    }
    @discardableResult func save(announce: Bool = false) -> Bool {
        guard !turns.isEmpty || !human.isEmpty || !material.isEmpty || hireMaterial != nil || !archivePath.isEmpty || recordingPath != nil else {
            if announce { judgmentSaveStatus = "请先写下你的判断" }
            return true
        }
        do {
            let dir = try archiveDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InterviewCopilot/Sessions", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let archive = SessionArchive(id: sessionID, date: startedAt, mode: mode, rubric: archivedRubric, material: material, turns: turns, frozen: frozen, human: human, comparison: comparison, hasGap: gap, hireMaterial: hireMaterial, asrHotwords: Hotwords.normalize(asrHotwords), comparedHuman: comparedHuman, originalTexts: originalTexts, cleanupDraft: cleanupDraft, recordingPath: recordingPath, previousReviews: previousReviews, cleanupProgress: cleanupProgress)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = dir.appendingPathComponent(sessionID.uuidString + ".json")
            try encoder.encode(archive).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            archivePath = url.path
            if self.error.hasPrefix("本地保存失败：") { self.error = "" }
            judgmentSaveStatus = human.isEmpty ? "本场记录已保存到本机（尚未填写判断）" : "我的判断已保存到本机"
            if announce { status = "我的判断已保存 · 可从「打开历史记录」恢复" }
            return true
        } catch {
            self.error = "本地保存失败：\(error.localizedDescription)"
            judgmentSaveStatus = "保存失败，修改尚未确认保存，请重试"
            return false
        }
    }
    @discardableResult func addManualTranscript(_ text: String) -> Bool {
        guard canChooseReviewTranscript else { return false }
        do {
            let parsed = try ManualTranscript.parse(text)
            let oldMode = mode, oldGap = gap
            turns = parsed; mode = "手动补充 · 面试记录"; gap = false
            guard save() else { turns = []; mode = oldMode; gap = oldGap; return false }
            error = ""; status = "已保存面试记录 · 来源为手动补充，可提交独立复核"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func savedSessions() throws -> [SavedSession] {
        let dir = try archiveDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InterviewCopilot/Sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(SessionArchive.self, from: data) else { return nil }
                return SavedSession(url: url, archive: archive)
            }
            .sorted { $0.archive.date == $1.archive.date ? $0.id.uuidString < $1.id.uuidString : $0.archive.date > $1.archive.date }
    }
    func openArchive(onRestore: @escaping () -> Void = {}) {
        guard !active, !busy, !ending, !importingMaterial else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("InterviewCopilot/Sessions")
        presentFilePanel(panel) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if self.restoreArchive(from: url) { onRestore() }
        }
    }
    @discardableResult func openLatestArchive() -> Bool {
        guard !active, !busy, !ending, !importingMaterial else { return false }
        do {
            let dir = try archiveDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("InterviewCopilot/Sessions", isDirectory: true)
            guard FileManager.default.fileExists(atPath: dir.path) else { status = "暂无本地保存的记录"; return false }
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            let dated = try files.filter { $0.pathExtension.lowercased() == "json" }.map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) }
            guard let latest = dated.max(by: { $0.1 < $1.1 })?.0 else { status = "暂无本地保存的记录"; return false }
            return restoreArchive(from: latest)
        } catch { self.error = "打开记录失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult func restoreArchive(from url: URL) -> Bool {
        guard !active, !busy, !ending, !importingMaterial else { return false }
        if !archivePath.isEmpty, URL(fileURLWithPath: archivePath).resolvingSymlinksInPath() == url.resolvingSymlinksInPath() {
            guard save() else { return false }
            status = "当前记录已保存并打开"; return true
        }
        do {
            let archive = try JSONDecoder().decode(SessionArchive.self, from: Data(contentsOf: url))
            guard save() else { return false }
            clearSession(); sessionID = archive.id; startedAt = archive.date; mode = archive.mode
            asrHotwords = archive.asrHotwords ?? Hotwords.defaults
            originalTexts = archive.originalTexts ?? [:]; cleanupDraft = archive.cleanupDraft ?? []
            recordingPath = archive.recordingPath; previousReviews = archive.previousReviews ?? []; cleanupProgress = archive.cleanupProgress
            cleanupStatus = cleanupDraft.isEmpty ? "" : "\(cleanupDraft.count) 段校对草稿待确认"
            archivedRubric = archive.rubric; material = archive.material; turns = archive.turns; frozen = archive.frozen
            human = archive.human
            comparison = archive.comparedHuman == archive.human ? archive.comparison : nil
            comparedHuman = comparison == nil ? nil : archive.comparedHuman
            revealed = archive.comparison != nil
            judgmentSaveStatus = human.isEmpty ? "已恢复本地记录（尚未填写判断）" : "已恢复本地保存的判断"
            hireMaterial = archive.hireMaterial; hireURL = archive.hireMaterial?.link.canonicalURL ?? ""
            if archive.hireMaterial != nil { importMessage = "已恢复飞书简历来源与本地文件" }
            if canResumeCleanup { cleanupStatus = "已有校对进度，可从未完成处继续" }
            gap = archive.hasGap; archivePath = url.path; status = gap ? "已恢复记录 · 存在转写缺口" : "已恢复本地记录"
            return true
        } catch { self.error = "打开记录失败：\(error.localizedDescription)"; return false }
    }
}
