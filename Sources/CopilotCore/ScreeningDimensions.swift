import Foundation

/// User-confirmed cross-role axes. Definitions operationalize the supplied diagram;
/// role-specific gates remain separate and no numeric weights are inferred.
public enum ScreeningDimensions {
    public struct Dimension: Identifiable, Sendable {
        public let id: String
        public let group: String
        public let name: String
        public let definition: String
        public let evidence: String
    }
    public static let version = "通用筛选维度 v1 · 2026-10-15"
    public static let items: [Dimension] = [
        .init(id: "online_sense", group: "内容能力", name: "网感", definition: "理解目标用户、社区语境和传播方式，能解释什么会引起关注以及为什么。", evidence: "具体用户洞察、社区观察、内容或产品调整及反馈；刷得多、粉丝多不直接证明网感。"),
        .init(id: "taste", group: "内容能力", name: "品味", definition: "能判断内容或产品体验的好坏，说明取舍理由，而非只表达个人喜好。", evidence: "作品对比、选择依据、修改前后与用户反馈；表达风格是否像面试官不作依据。"),
        .init(id: "creation", group: "内容能力", name: "创作能力", definition: "能亲自产出面向目标受众的清晰内容，把想法做成可查看的作品。", evidence: "文章、演示、视频、产品说明或技术文档中的本人产出与迭代；岗位不要求公开发布时，不强求个人账号或爆款。"),
        .init(id: "ai_understanding", group: "技术理解", name: "AI 理解", definition: "理解 AI 的能力、局限与使用条件，能结合实际任务解释选择、验证和失败。", evidence: "本人使用或建设 AI 的具体过程、评估、失败处理及结果；模型名和工具清单不足以证明理解，不统一要求训练模型。"),
        .init(id: "product_understanding", group: "技术理解", name: "产品理解", definition: "理解为谁解决什么问题，能把技术能力与用户价值、使用流程和约束联系起来。", evidence: "真实任务、需求取舍、验收依据及反馈；技术术语正确不等于理解产品，不强求人人担任产品负责人。"),
        .init(id: "execution", group: "执行力", name: "执行力", definition: "在具体资源与不确定性约束下，亲自推进、交付、验证并根据反馈迭代。", evidence: "本人责任、关键行动、交付物、结果及持续跟进；区分团队成果和个人贡献，不用忙碌、工时或管理人数代替执行力。")
    ]
    public static let boundaries = """
    六项对所有岗位都保留，但深度与优先级按本岗责任和明确硬门槛判断；未校准时不编造数字权重、不计算总分、不以强项抵消核心能力缺口。
    内容/增长岗位重点核验受众洞察、创作和传播效果；产品/应用岗位结合用户体验与交付；工程/研究/数据岗位结合本职设计、实验、文档及可验证成果，不一律要求公开内容、粉丝量或商业产品上线；后勤岗位结合招聘、财务、运营等本职任务及 AI 使用，不能要求人人成为技术专家。这些是维度的取证方式，不是新增统一硬门槛。
    每项区分有具体自述证据、存在相反证据、证据不足/待验证；缺证不等于低能力，也不能自动填中等。简历和面试自述不等于外部核实；证据只支持其实际覆盖范围。
    原图是两条轴（内容能力、技术理解）加圆大小（执行力），没有数值标尺；右上且执行强代表组合优势，不是所有岗位统一录用线。职业名称和圆的位置只是示意，不得据此推断某位工程师没网感、某位创作者不懂技术。
    """
    public static var text: String {
        ([version] + items.map { "\($0.group) / \($0.name)：\($0.definition) 取证：\($0.evidence)" } + [boundaries]).joined(separator: "\n")
    }
}
