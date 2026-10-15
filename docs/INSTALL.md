# 安装与更新

## 准备环境

需要 macOS 15+、Xcode 16+ 和 Python 3。首次打开 Xcode 完成组件安装及许可确认。只安装 Command Line Tools 不足以运行 XCTest。

在源码目录执行：

```bash
bash scripts/doctor.sh
```

此脚本只检查环境。自定义 Xcode 可通过 `DEVELOPER_DIR` 指定：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/check.sh
```

首次构建下载固定版本的 sherpa-onnx 和 ONNX Runtime 二进制依赖，需要访问 GitHub。

## 配置开发签名

固定签名身份用于后续构建保持一致身份。专用本机证书只用于自己的电脑，公开安装包使用 Developer ID。

确认同意创建证书及代码签名用途信任后执行：

```bash
python3 scripts/setup-local-signing.py --confirm-local-signing
```

脚本使用用户钥匙串；私钥不可导出，仅预授权 codesign 使用，不添加 TLS 信任。macOS 请求身份验证时由操作者完成。

已有有效签名身份时，也可直接指定：

```bash
COPILOT_SIGNING_IDENTITY='证书名称或指纹' bash scripts/build-app.sh
```

## 构建与首次使用

```bash
bash scripts/build-app.sh
open dist/InterviewCopilot.app
```

1. 设置中下载并校验本地语音模型。
2. 安装并登录 Codex，点击“检测 Codex 连接”。转写本身不需要 Codex。
3. 通过应用申请麦克风、录屏与系统录音权限，在系统设置中允许当前应用，按提示重新打开。
4. 打开电脑微信，在获得对方同意后检测两路输入并开始面试。

应用只采集声音，不保存屏幕画面。录屏权限用于 ScreenCaptureKit 的微信应用音频采集。

## Codex 路径

自动查找系统与用户 Applications 中的 Codex / ChatGPT、Homebrew、`~/.local/bin` 和进程 PATH 中的 codex。

Finder 启动的应用可能没有终端 PATH。可在设置中点击“选择 Codex…”，选择 `command -v codex` 显示的文件；用 Command-Shift-G 输入路径。选错后点击“自动查找”。指定路径失效时明确报错，不会悄悄换用另一安装。

命令行诊断可设置 `COPILOT_CODEX_PATH` 为绝对路径。应用通过 [Codex App Server](https://learn.chatgpt.com/docs/app-server) 复用本机登录与配置，不复制认证令牌、不修改全局设置。文字处理在明确提交后进行。

## 飞书导入（可选）

使用已配置的本机 lark-cli Bot，需要人才、附件及预览读取权限。应用只读取人才和附件，不读取面评或备注，不写回招聘系统。

没有飞书连接时使用本地 PDF / 文本导入。应用不携带维护者账号。

## 更新已有应用

先保存并完全退出应用，再运行构建脚本。默认输出 `dist/InterviewCopilot.app`；需要独立目录时指定 `COPILOT_APP_OUTPUT`。

覆盖前核对旧包签名身份，失败时保留旧包。首次从 ad-hoc 迁移到证书签名，或主动更换身份时，明确执行一次：

```bash
COPILOT_ALLOW_SIGNING_MIGRATION=1 bash scripts/build-app.sh
```

身份迁移后可能需要重新授权。正常更新不使用该开关。

权限开启后仍被拒绝时，确认运行的是新安装的应用，并完全退出后重开。不要关闭系统 Gatekeeper 或全局重置隐私权限。

卸载应用不会自动删除面试记录，见 [隐私与数据](PRIVACY.md)。
