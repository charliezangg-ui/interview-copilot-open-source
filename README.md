# Interview Copilot · 面试助手

原生 macOS 面试记录与独立复核工具。通过电脑微信采集双方声音，在本机转写；面试结束后，通过本机 Codex 整理文字、生成独立初评并对照面试官的判断。

Native macOS interview notes with on-device speech recognition and Codex-assisted review.

## 功能

- **现场记录**：麦克风与微信音频分轨采集、本地录音、流式转写和发言时间线。
- **文字整理**：逐段编辑或生成校对草稿；确认后显示整理后的正文，支持回听录音。
- **独立复核**：先生成独立初评，再对照面试官判断；点击评语引用跳转到对应发言。
- **材料与存档**：导入 PDF / 文本，选用飞书招聘导入；本地保存、恢复历史，支持补充实际问答。

## 环境

| 项目 | 要求 |
| --- | --- |
| 系统 | macOS 15 或更新版本 |
| 源码构建 | Xcode 16+、Swift 6 工具链、Python 3 |
| 音频来源 | 电脑微信与本机麦克风 |
| 语音模型 | sherpa-onnx 中英 Zipformer，首次下载约 199 MB |
| 文字整理与复核 | 已安装并登录的 Codex |
| 飞书导入（可选） | 已配置 Bot 权限的 lark-cli |

语音模型安装后可离线转写。文字处理通过 Codex 发送文本到其配置的服务，需要网络及相应账号访问权限；应用不另设模型 API Key 入口。

## 从源码运行

在源码目录执行环境检查：

```bash
bash scripts/doctor.sh
```

首次本地构建需要固定代码签名身份。确认同意创建专用开发证书及仅限代码签名的本机信任后执行：

```bash
python3 scripts/setup-local-signing.py --confirm-local-signing
bash scripts/build-app.sh
open dist/InterviewCopilot.app
```

已有签名证书、自定义 Xcode 路径或更新旧版时，参见 [安装说明](docs/INSTALL.md)。创建证书时可能出现 macOS 身份验证窗口。

## 使用流程

1. 在“面前准备”导入候选人材料。
2. 打开“Codex 与语音转录”，下载模型并检测 Codex 连接；可自动查找或手动选择 Codex。
3. 获得对方录音及转写同意后，检测麦克风与微信两路输入，开始面试。
4. 结束后核对时间线，按需编辑或生成文字校对草稿，确认应用。
5. 保存自己的判断，提交独立复核；点击引用查看对应发言。

原音频保存在本机。文字校对只发送转写与术语表；独立初评使用材料和面试记录，面试官判断仅进入之后的对照。发送前应用提示处理范围。数据位置和删除方法见 [隐私与数据](docs/PRIVACY.md)。

## 开发与参与

```bash
bash scripts/check.sh
bash scripts/scan-secrets.sh
python3 scripts/export-source.py
```

源码导出到 `dist/source/`，附文件清单与 SHA-256。

- [贡献指南](CONTRIBUTING.md) · [测试说明](docs/VALIDATION.md) · [界面验收](docs/GUI-ACCEPTANCE.md)
- [功能定义](docs/REQUIREMENTS.md) · [发布流程](docs/RELEASING.md) · [更新记录](CHANGELOG.md)
- [安全问题反馈](SECURITY.md)

## 技术结构

| 目录 | 用途 |
| --- | --- |
| `Sources/InterviewCopilot` | SwiftUI、音频采集、存档与工作流程 |
| `Sources/LocalASR` | 语音模型下载、校验与本地解码 |
| `Sources/CodexIntegration` | 本机 Codex 发现与 App Server 连接 |
| `Sources/CopilotCore` | 数据模型、校对规则、提示词与证据校验 |
| `Sources/HireIntegration` | 可选飞书读取与本地简历解析 |
| `Tests` | 使用合成数据的自动测试 |

接口参考 [Codex 官方 App Server 文档](https://learn.chatgpt.com/docs/app-server)。模型权重单独下载，版本、大小及 SHA-256 固定在 `Sources/LocalASR/model-manifest.json`。

## 许可

项目代码采用 [MIT License](LICENSE)，版权所有 © 2026 charliezangg-ui。第三方组件和模型按各自许可证分发，见 [第三方声明](Resources/THIRD_PARTY_NOTICES.md)。
