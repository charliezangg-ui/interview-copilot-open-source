import SwiftUI
import AppKit
import CopilotCore

@main struct InterviewCopilotApp: App {
    @StateObject private var store = SessionStore()
    var body: some Scene {
        WindowGroup("面试助手") { WorkspaceView().environmentObject(store).frame(minWidth: 1100, minHeight: 740) }
            .defaultSize(width: 1280, height: 850)
        Settings { SettingsView().environmentObject(store).frame(width: 590, height: 590) }
    }
}
private let accent = Color(red: 0.12, green: 0.40, blue: 0.36)
private let canvas = Color(red: 0.96, green: 0.965, blue: 0.95)

struct WorkspaceView: View {
    @EnvironmentObject var store: SessionStore
    @State private var section = "现场辅助"
    @State private var settings = false
    @State private var confirmReview = false
    @State private var showCleanup = false
    @State private var showHistory = false
    @State private var showManualTranscript = false
    @State private var editingTurn: Utterance?
    @State private var highlighted = Set<String>()
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Divider()
                if !store.error.isEmpty {
                    HStack { Image(systemName: "exclamationmark.triangle"); Text(store.error).font(.callout); Spacer()
                        if store.error.contains("录屏与系统录音授权未生效") {
                            Button("请求录屏与系统录音授权") { Task { await store.requestScreenAuthorization() } }
                                .disabled(store.busy || store.active || store.ending)
                            Button("打开系统设置") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                            }
                        }
                        Button("收起") { store.error = "" } }.padding(12).background(Color.orange.opacity(0.12))
                }
                Group {
                    switch section {
                    case "面前准备": preparation
                    case "独立复核": review
                    default: liveWorkspace
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 8) {
                    Circle().fill(store.active ? Color.green : Color.gray).frame(width: 6, height: 6)
                    Text(store.status).lineLimit(2)
                    Spacer()
                    Text("Interview Copilot · 本地存档").foregroundStyle(.secondary)
                }.font(.caption).padding(.horizontal, 24).padding(.vertical, 12).background(.white)
            }.background(canvas)
        }.tint(accent).preferredColorScheme(.light)
        .sheet(isPresented: $settings) { SettingsView().environmentObject(store).frame(width: 590, height: 590) }
        .sheet(isPresented: $confirmReview) { ReviewSubmissionView().environmentObject(store) }
        .sheet(isPresented: $showManualTranscript) { ManualTranscriptView().environmentObject(store) }
        .sheet(isPresented: $showHistory) {
            SessionHistoryView { section = "独立复核"; highlighted = [] }.environmentObject(store)
        }
        .sheet(isPresented: $showCleanup) { TranscriptCleanupView().environmentObject(store) }
        .sheet(item: $editingTurn) { turn in TranscriptEditView(turn: turn).environmentObject(store) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 10) { Image(systemName: "waveform.path").font(.title2); Text("面试助手").font(.title3.bold()) }.padding(.top, 15)
            Text("INTERVIEW COPILOT").font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.white.opacity(0.55))
            VStack(spacing: 8) {
                nav("面前准备", icon: "doc.text.magnifyingglass", sub: "候选人材料")
                nav("现场辅助", icon: "waveform", sub: "跟随你的节奏")
                nav("独立复核", icon: "square.split.2x2", sub: "你先判断，助手再验证")
            }
            Divider().overlay(.white.opacity(0.15))
            VStack(alignment: .leading, spacing: 12) {
                Text("本场记录").font(.caption).foregroundStyle(.white.opacity(0.6))
                Text(store.mode).font(.callout)
                Label("\(store.turns.count) 段发言", systemImage: "text.bubble")
            }.font(.caption)
            Spacer()
            Menu {
                Button("浏览历史面试…") { if store.save() { showHistory = true } }
                Button("恢复最近保存的记录") { if store.openLatestArchive() { section = "独立复核" } }
                Button("选择存档文件…") { store.openArchive { section = "独立复核" } }
            } label: { Label("打开历史记录", systemImage: "folder") }.menuStyle(.borderlessButton).disabled(store.active || store.busy || store.ending)
            Button { if store.reset() { section = "面前准备"; highlighted = [] } } label: { Label("新建面试", systemImage: "plus") }.buttonStyle(.plain).disabled(store.active || store.busy || store.ending)
            Button { settings = true } label: { Label("Codex 与语音转录", systemImage: "slider.horizontal.3") }.buttonStyle(.plain).disabled(store.active || store.busy || store.ending)
        }.padding(24).frame(width: 190).foregroundStyle(.white).background(Color(red: 0.12, green: 0.20, blue: 0.19))
    }
    private func nav(_ title: String, icon: String, sub: String) -> some View {
        Button { section = title } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 14, weight: .semibold)); Text(sub).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)) }
                Spacer(minLength: 0)
            }.padding(12).background(section == title ? .white.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(section).font(.system(size: 24, weight: .semibold))
                Text(section == "现场辅助" ? "记录双方原话，结束后回听并校对。" : section == "独立复核" ? "你的评价是待检验的观点，候选人的回答才是依据。" : "导入候选人材料，准备记录本次面试。").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(store.canCloud ? "云端分析已允许" : "本地转写 · 云端分析未开启").font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7).background(accent.opacity(0.08)).clipShape(Capsule())
        }.padding(24)
    }
    private var preparation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card {
                    HStack { Text("从飞书招聘导入").font(.headline); Spacer(); if store.importingMaterial { ProgressView().controlSize(.small) } }
                    HStack {
                        TextField("粘贴候选人详情链接", text: $store.hireURL).textFieldStyle(.roundedBorder)
                        Button("解析并导入") { Task { await store.importHireLink() } }.buttonStyle(.borderedProminent).disabled(store.hireURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("复用本机飞书连接。按附件时间优先导入最新简历；替换正文可撤销。仅下载到本机，不读取面评或备注。").font(.caption).foregroundStyle(.secondary)
                    if let candidate = store.hireCandidate, candidate.resumes.count > 1 {
                        HStack {
                            Picker("其他简历", selection: $store.selectedResumeID) {
                                ForEach(candidate.resumes) { item in Text(item.name + (item.createdAt.map { " · " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .numeric, time: .omitted) } ?? " · 日期未知")).tag(item.id) }
                            }
                            Button("导入所选") { Task { await store.importSelectedResume() } }
                        }
                    }
                    if !store.importMessage.isEmpty { Text(store.importMessage).font(.callout).foregroundStyle(accent) }
                    HStack {
                        if let source = store.hireMaterial {
                            Text(source.candidateName).font(.callout.bold())
                            Button("查看简历附件") { NSWorkspace.shared.open(URL(fileURLWithPath: source.localPath)) }
                        }
                        if store.canUndoImport { Button("撤销正文替换") { store.undoImport() } }
                    }
                }.disabled(!store.canEditMaterial)
                if store.frozen != nil {
                    Text("独立初评已固定，本场材料已锁定，避免修改原评估依据。").font(.caption).foregroundStyle(.secondary)
                } else if store.active {
                    Text("面试中可补充材料，导入不会中断录音。").font(.caption).foregroundStyle(.secondary)
                }
                card {
                    HStack { Text("候选人材料").font(.headline); Spacer(); Button("导入 PDF / 文本") { store.importMaterial() } }
                    Text("飞书简历自动填入下方；也可手动粘贴简历、JD 或脱敏项目说明。其他项目链接暂不自动抓取。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $store.material).font(.body).frame(height: 190).padding(8).background(canvas).clipShape(RoundedRectangle(cornerRadius: 8))
                }.disabled(!store.canEditMaterial)
                card {
                    Text("所有岗位共用的筛选维度").font(.headline)
                    Text(ScreeningDimensions.version).font(.caption).foregroundStyle(.secondary)
                    Text("内容能力：网感、品味、创作能力 · 技术理解：AI 理解、产品理解 · 执行力").font(.callout)
                    Text("固定保留这六项；按岗位选择证据与深度，不统一打分，也不替代本岗硬门槛。").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("查看定义与取证标准") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ScreeningDimensions.items) { item in
                                Text("\(item.group) / \(item.name)").font(.subheadline.bold())
                                Text(item.definition).font(.callout)
                                Text(item.evidence).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(ScreeningDimensions.boundaries).font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                    if store.frozen != nil {
                        Text("本场已有固定初评，仍以其保存的标准为准；新维度不会追溯改写旧评价。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("进入现场辅助") { section = "现场辅助" }.buttonStyle(.borderedProminent)
            }.padding(24)
        }
    }
    private var liveWorkspace: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Button("检测音频") { Task { await store.startAudioCheck() } }.disabled(store.active || store.busy || store.ending || !store.turns.isEmpty || !store.informed)
                Button { Task { await store.startLive() } } label: { Label("开始微信面试", systemImage: "mic") }.buttonStyle(.borderedProminent).disabled(store.active || store.busy || store.ending || !store.turns.isEmpty || !store.canTranscribe || !store.informed)
                if store.active { Button(store.checkingAudio ? "停止检测" : "结束面试") { Task { await store.finish() } }.tint(.red) }
                if store.busy || store.ending { ProgressView().controlSize(.small) }
                Spacer()
                meter("我的麦克风", store.microphoneLevel)
                meter("微信声音", store.candidateLevel)
            }
            if store.hasAudioCheck {
                HStack {
                    Text("本次检测 · 麦克风：\(store.microphoneProbe.summary) · 微信：\(store.candidateProbe.summary)")
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
                if !store.active && !store.candidateProbe.heardSound {
                    Text("请在电脑微信播放语音后重新检测；若仍无声音，请检查是否切换了输出设备。检测只查看电平，不生成转写。").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.active && store.turns.isEmpty {
                HStack { Toggle("已告知对方并获得录音 / 转写同意", isOn: $store.informed).font(.caption); Spacer(); Button("语音转录设置") { settings = true } }
                Text("微信与麦克风分别在本机录音并转写。录音仅保存在本机，可在结束后回听；建议戴耳机避免串音。文字校对需另行允许发送文本。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !store.audioWarning.isEmpty {
                Label(store.audioWarning, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            transcript.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(24)
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("对话时间线").font(.headline)
                Spacer()
                if !store.active && !store.ending && !store.turns.isEmpty {
                    Button(store.cleanupDraft.isEmpty ? "优化转写文字" : "查看校对草稿（\(store.cleanupDraft.count)）") { showCleanup = true }.disabled(store.busy)
                }
                Text("来源分轨 · 片段时间").font(.caption).foregroundStyle(.secondary)
            }
            if !store.active && !store.ending {
                HStack {
                    if store.recordingPath != nil {
                        Button(store.playingTrack == .interviewer ? "停止我的录音" : "回听我的录音") { store.playRecording(.interviewer) }
                        Button(store.playingTrack == .candidate ? "停止微信录音" : "回听微信录音") { store.playRecording(.candidate) }
                        Button("打开录音文件") { if let path = store.recordingPath { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
                    } else if !store.turns.isEmpty {
                        Text("这份记录没有保存原音频；只能校对现有文字，无法补回漏录。 ").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                if !store.cleanupStatus.isEmpty { Text(store.cleanupStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Divider()
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if store.turns.isEmpty {
                            VStack(spacing: 15) { Image(systemName: "waveform.path").font(.system(size: 40)).foregroundStyle(accent.opacity(0.5)); Text("对话会在这里展开").font(.headline); Text("先检测两路收音，再开始微信面试。").multilineTextAlignment(.center).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 85)
                        }
                        ForEach(store.turns) { turn in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text(turn.speaker.rawValue).font(.caption.bold()); Text(turn.manuallyAdded == true ? "手动补充 · 未经录音核对" : String(format: "%02d:%02d", Int(turn.seconds) / 60, Int(turn.seconds) % 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary); Spacer() }
                                    Text(turn.text).font(.system(size: 14)).lineSpacing(4).textSelection(.enabled)
                                    if !store.active && !store.ending {
                                        Button("校正这段文字") { editingTurn = turn }.font(.caption).disabled(store.busy || !store.cleanupDraft.isEmpty)
                                    }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(highlighted.contains(turn.id) ? Color.yellow.opacity(0.22) : turn.speaker == .candidate ? canvas : .clear).clipShape(RoundedRectangle(cornerRadius: 9)).id(turn.id)
                        }
                        if !store.partialHR.isEmpty { Text("HR（转写中）：\(store.partialHR)").foregroundStyle(.secondary) }
                        if !store.partialCandidate.isEmpty { Text("候选人（转写中）：\(store.partialCandidate)").foregroundStyle(.secondary) }
                        Color.clear.frame(height: 1).id("bottom")
                    }.padding(.vertical, 6)
                }.onChange(of: store.turns.count) { _, _ in if highlighted.isEmpty { withAnimation { reader.scrollTo("bottom", anchor: .bottom) } } }
                    .task(id: highlighted) {
                        // The transcript appears after navigation; scroll after layout.
                        await Task.yield()
                        if let first = store.turns.first(where: { highlighted.contains($0.id) }) { reader.scrollTo(first.id, anchor: .center) }
                    }
            }
        }.padding(18).background(.white).clipShape(RoundedRectangle(cornerRadius: 14))
    }
    private var review: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                card {
                    HStack { Text("01  先写下你的判断").font(.headline); Spacer(); Text(store.frozen == nil ? "独立初评尚未固定" : "独立初评已固定 · 未读取你的评价").font(.caption).foregroundStyle(accent) }
                    TextEditor(text: $store.human).frame(height: 100).padding(8).background(canvas).clipShape(RoundedRectangle(cornerRadius: 8)).disabled(store.active || store.busy || store.ending)
                    HStack {
                        Button("保存我的判断") { store.save(announce: true) }.disabled(store.active || store.busy || store.ending)
                        Button(store.canChooseReviewTranscript ? "补充面试记录，继续提交" : "提交判断，查看独立对照") {
                            if store.canChooseReviewTranscript { if store.save() { showManualTranscript = true } }
                            else if store.canCloud { Task { await store.submitJudgment() } }
                            else if store.save(announce: true) { confirmReview = true }
                        }.buttonStyle(.borderedProminent).disabled(store.reviewBlocker != nil && !store.canChooseReviewTranscript)
                        if store.busy { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        Text(store.judgmentSaveStatus.isEmpty ? "你的判断可直接保存到本机，无需连接模型。" : store.judgmentSaveStatus).font(.caption)
                        Spacer()
                        if !store.archivePath.isEmpty {
                            Button("在 Finder 中查看存档") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: store.archivePath)]) }.font(.caption)
                        }
                    }
                    if let blocker = store.reviewBlocker { Text(blocker).font(.caption).foregroundStyle(.secondary) }
                    if store.canChooseReviewTranscript {
                        HStack {
                            Button("前往现场辅助，检测收音") { section = "现场辅助" }
                            Button("查看历史面试…") { if store.save() { showHistory = true } }
                        }.font(.caption)
                    }
                    if !store.turns.isEmpty && !store.canCloud {
                        Text("点击提交后自动连接本机 Codex；确认后完成独立复核。").font(.caption).foregroundStyle(.secondary)
                    }
                    if store.frozen == nil && !store.turns.isEmpty { Text("提交时先独立分析候选人的回答，再对照你的判断；无需手动生成初评。").font(.caption).foregroundStyle(.secondary) }
                }
                if store.revealed, let frozen = store.frozen {
                    card {
                        HStack { Text("02  助手的独立初评").font(.headline); Spacer(); Button("复制评语") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(frozen.assessment.comment, forType: .string) } }
                        evidenceText(frozen.assessment.comment)
                        Button("查看候选人发言") { highlighted = Set(frozen.assessment.evidenceIDs); section = "现场辅助" }
                    }
                    card {
                        Text("03  你的观点是否有证据支持").font(.headline)
                        if store.comparison == nil { Text("当前判断尚未复核，请重新提交；独立初评保持不变。").font(.callout).foregroundStyle(.secondary) }
                        ForEach(Array((store.comparison?.items ?? []).enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text(item.claim).font(.headline); Spacer(); Text(item.status).font(.caption).foregroundStyle(accent) }
                                evidenceText(item.reason).font(.callout)
                                if !item.evidenceIDs.isEmpty { Button("定位依据") { highlighted = Set(item.evidenceIDs); section = "现场辅助" } }
                            }.padding(.vertical, 10)
                            Divider()
                        }
                    }
                } else {
                    card { Label("你的观点不会作为模型初评的支撑", systemImage: "lock.shield").font(.headline); Text("独立初评使用通用筛选维度、候选人材料和面试记录。你提交判断后，才进行证据对照；已有初评保持不变。").foregroundStyle(.secondary) }
                }
            }.padding(24)
        }
    }
    private func evidenceText(_ text: String) -> some View {
        Text(EvidenceReferences.attributed(text, in: store.turns))
            .textSelection(.enabled).lineSpacing(5)
            .environment(\.openURL, OpenURLAction { url in
                guard let id = EvidenceReferences.target(of: url, in: store.turns) else { return .discarded }
                highlighted = [id]
                section = "现场辅助"
                return .handled
            })
    }
    private func meter(_ label: String, _ level: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.caption2); ProgressView(value: min(Double(level) * 12, 1)).frame(width: 72) }
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(20).background(.white).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
struct ManualTranscriptView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var issue = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("补充这场面试的记录").font(.title2.bold())
            Text("填写实际问答或面试笔记，每次换人用“HR：”或“候选人：”开头。这里的内容将用于独立初评；你的判断仍单独保存。").font(.callout)
            Text("格式示例：\nHR：你在项目中具体负责什么？\n候选人：我负责……").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(height: 230).padding(8).background(canvas)
            Text("记录将标记为手动补充，不标记为录音原话。只补充能确认的内容；不能把“复杂度低、淘汰”等判断当成候选人的回答。").font(.caption).foregroundStyle(.secondary)
            if !issue.isEmpty { Text(issue).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存面试记录，返回提交") {
                    if store.addManualTranscript(text) { dismiss() }
                    else { issue = store.error }
                }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 700)
    }
}

struct SessionHistoryView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let onRestore: () -> Void
    @State private var sessions: [SavedSession] = []
    @State private var selected: UUID?
    @State private var withTranscriptOnly = true
    @State private var loadError = ""
    private var visibleSessions: [SavedSession] { sessions.filter { !withTranscriptOnly || !$0.archive.turns.isEmpty } }
    private var selection: SavedSession? { visibleSessions.first { $0.id == selected } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择面试记录").font(.title2.bold())
            Text("当前判断已保存在本机。按面试时间和内容选择对应记录，打开后再提交。").font(.callout).foregroundStyle(.secondary)
            Toggle("只显示有面试发言的记录", isOn: $withTranscriptOnly)
            HStack(alignment: .top, spacing: 18) {
                List(visibleSessions, selection: $selected) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.archive.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text("\(item.archive.turns.count) 段发言 · \(item.archive.human.isEmpty ? "未填写判断" : "已保存判断")").font(.caption)
                        Text(item.archive.mode).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 6).tag(item.id)
                }.frame(width: 270)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let item = selection {
                            Text("记录预览").font(.headline)
                            if let name = item.archive.hireMaterial?.candidateName { Text(name).font(.callout.bold()) }
                            if !item.archive.human.isEmpty {
                                Text("这份记录中保存的判断").font(.caption.bold())
                                Text(item.archive.human).font(.callout).textSelection(.enabled)
                            }
                            if item.archive.hasGap { Text("这份记录有转写缺口，仍需补齐后复核。").font(.caption).foregroundStyle(.orange) }
                            if item.archive.turns.isEmpty { Text("没有面试发言，打开后仍无法独立复核。").foregroundStyle(.secondary) }
                            ForEach(Array(item.archive.turns.prefix(5))) { turn in
                                Text("\(turn.speaker.rawValue)：\(turn.text)").font(.callout).textSelection(.enabled)
                            }
                        } else { Text("选择一份记录，核对是否为同一场面试。").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }.frame(height: 310)
            if !loadError.isEmpty { Text(loadError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("选择其他存档文件…") {
                    store.openArchive { onRestore(); dismiss() }
                }
                Spacer()
                Button("打开所选面试") {
                    if let item = selection {
                        if store.restoreArchive(from: item.url) { onRestore(); dismiss() }
                        else { loadError = store.error }
                    }
                }.buttonStyle(.borderedProminent).disabled(selection == nil)
            }
        }.padding(26).frame(width: 820)
            .onAppear {
                do { sessions = try store.savedSessions() }
                catch { loadError = "读取历史记录失败：\(error.localizedDescription)" }
            }
            .onChange(of: withTranscriptOnly) { _, _ in selected = nil }
    }
}

struct TranscriptEditView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    let turn: Utterance
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校正这段文字").font(.title2.bold())
            Text("结合录音核对错字和标点，保留原意；没有录到的内容不能凭推测补写。").font(.callout).foregroundStyle(.secondary)
            Text(turn.text).font(.callout).textSelection(.enabled)
            TextEditor(text: $text).font(.body).frame(height: 200).padding(8).background(canvas)
            if store.frozen != nil { Text("正文修改后会重新复核；旧初评保留在本地存档中。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存正文") {
                    if store.applyTranscriptEdits([.init(id: turn.id, text: text)]) { dismiss() }
                }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == turn.text)
            }
            if !store.error.isEmpty { Text(store.error).font(.caption).foregroundStyle(.red) }
        }.padding(26).frame(width: 660).onAppear { text = turn.text }
    }
}

struct TranscriptCleanupView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("优化转写文字").font(.title2.bold())
            Text("纠正误词、整理断句和无意义重复，保留原意与责任边界。无法确认的词标为待核对；确认后只显示整理后的正文。").font(.callout).foregroundStyle(.secondary)
            if store.cleanupDraft.isEmpty {
                if !store.canCloud {
                    Text("通过本机 Codex 优化文字").font(.headline)
                    Text("此次会通过本机 Codex 发送本场转写与术语表进行分析。录音、简历和你的判断不发送；仅允许这次校对，不开启自动云端分析。").font(.callout)
                }
                Button(store.canResumeCleanup ? (store.canCloud ? "继续未完成的校对" : "允许发送文本，继续校对") : (store.canCloud ? "生成校对草稿" : "允许发送文本，生成草稿")) {
                    Task {
                        if store.canCloud { await store.generateCleanup() }
                        else { await store.confirmAndGenerateCleanup() }
                    }
                }.buttonStyle(.borderedProminent).disabled(store.busy)
                if store.canResumeCleanup && !store.busy { Button("放弃已保存的校对进度") { store.discardCleanup() } }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(store.cleanupDraft) { edit in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("校对前").font(.caption.bold()).foregroundStyle(.secondary)
                                Text(store.turns.first(where: { $0.id == edit.id })?.text ?? "").foregroundStyle(.secondary)
                                Text("校对后").font(.caption.bold()).foregroundStyle(accent)
                                Text(edit.text).textSelection(.enabled)
                                Button("这段保留原文") { store.keepOriginalText(edit.id) }.font(.caption)
                                Divider()
                            }.font(.callout)
                        }
                    }
                }
                Text("确认每段原意后再应用；有误的片段可选择保留原文。已有复核会失效，旧初评保留存档。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("放弃草稿") { store.discardCleanup(); dismiss() }
                    Spacer()
                    Button("确认并应用正文") { if store.applyTranscriptEdits(store.cleanupDraft) { dismiss() } }.buttonStyle(.borderedProminent)
                }
            }
            if store.cleanupRunning {
                if let progress = store.cleanupProgress {
                    ProgressView(value: Double(progress.completedBatches), total: Double(max(1, TranscriptCleanup.batches(progress.source).count)))
                }
                HStack {
                    ProgressView().controlSize(.small)
                    Text(store.cleanupStatus).font(.callout)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("已用时 \(Int(context.date.timeIntervalSince(store.cleanupStartedAt ?? context.date))) 秒").font(.caption).monospacedDigit()
                    }
                }
                Button("停止校对，保留进度") { store.cancelCleanup() }
            }
            else if !store.cleanupStatus.isEmpty { Text(store.cleanupStatus).font(.caption).foregroundStyle(.secondary) }
            if !store.error.isEmpty { Text(store.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("关闭") { dismiss() }.disabled(store.busy).keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 740, height: 600).interactiveDismissDisabled(store.busy)
    }
}

struct ReviewSubmissionView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var submitting = false
    @State private var failure = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("提交独立复核").font(.title2.bold())
            Text("复用这台电脑的 Codex 登录。确认后自动连接并继续提交，无需前往设置。")
                .font(.callout)
            Text("此次提交会将通用筛选维度、候选人材料和面试转写通过本机 Codex 发送到云端进行分析；你的判断仅用于之后的证据对照，不进入独立初评。原音频不上传。")
                .font(.callout).foregroundStyle(.secondary)
            Text("本次确认仅授权这次提交，不会开启后续面试的自动云端分析。").font(.caption).foregroundStyle(.secondary)
            if store.frozen != nil { Text("独立初评已固定，本次只继续证据对照。").font(.caption).foregroundStyle(accent) }
            if submitting {
                HStack { ProgressView().controlSize(.small); Text(store.status).font(.callout) }
            }
            if !failure.isEmpty { Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("取消") { dismiss() }.disabled(submitting).keyboardShortcut(.cancelAction)
                Spacer()
                Button(failure.isEmpty ? "允许分析并提交" : store.frozen == nil ? "重试独立复核" : "重试对照") {
                    submitting = true; failure = ""
                    Task {
                        let completed = await store.confirmAndSubmitJudgment()
                        submitting = false
                        if completed { dismiss() }
                        else { failure = store.error.isEmpty ? store.status : store.error }
                    }
                }.buttonStyle(.borderedProminent).disabled(submitting || store.reviewBlocker != nil)
            }
        }.padding(26).frame(width: 560)
            .interactiveDismissDisabled(submitting)
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Codex 与语音转录").font(.title2.bold())
            Text("本机 Codex · 文本分析").font(.headline)
            HStack { Text(store.codexStatus).font(.caption); Spacer(); Button("检测 Codex 连接") { Task { await store.connectCodex() } } }
            HStack {
                Text(store.codexExecutablePath.isEmpty ? "自动查找已安装的 Codex" : store.codexExecutablePath)
                    .font(.caption).lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("选择 Codex…") { store.chooseCodexExecutable() }
                if !store.codexExecutablePath.isEmpty { Button("自动查找") { store.setCodexExecutable("") } }
            }
            Text("Codex 复用本机登录和模型配置，无需复制凭据。文字优化和独立复核使用单独上下文，关闭共享 Memory 与外部工具，不读取其他聊天。").font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("本地转写 · sherpa-onnx 中英 Zipformer").font(.headline)
            HStack { Text(store.localModelStatus).font(.caption); Spacer(); Button(store.localModelReady ? "校验 / 修复模型" : "下载模型（约 199 MB）") { Task { await store.prepareLocalModel() } } }
            Text("本场术语（每行一个，最多 64 项；新建面试恢复默认）").font(.caption)
            TextEditor(text: $store.asrHotwords).font(.system(.body, design: .monospaced)).frame(height: 80).border(.gray.opacity(0.2))
            Toggle("本次运行允许发送简历 / 转写文本到云端分析", isOn: $store.allowCloud)
            Text("面试原音频分为麦克风和微信两条 WAV，仅保存在本机，不上传。音频检测不录盘。模型首次下载后可离线转写。").font(.caption).foregroundStyle(.secondary)
            Text("结束后可优化转写文字，确认草稿后应用；也可逐段手动校正。文字模型无法恢复漏录或保证专名正确，需结合录音核对。").font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack { Button("打开本地存档目录") { let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InterviewCopilot"); NSWorkspace.shared.open(dir) }; Spacer(); Button("完成") { dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(26).disabled(store.active || store.busy || store.ending)
        }
    }
}
