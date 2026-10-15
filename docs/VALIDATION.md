# 测试与检查

本页提供可执行的检查方式。实际结果以对应版本的测试日志和 GitHub Actions 为准。

## 自动检查

```bash
bash scripts/check.sh
bash scripts/scan-secrets.sh
```

- 源码检查：公开文件范围、意外二进制、私钥、令牌及个人绝对路径。
- Swift 测试：数据解析、证据引用、存档恢复、校对、复核、权限检查及音频处理。
- Release 编译：验证优化构建可完成。
- Gitleaks：扫描已提交历史和当前公开源码，密钥值在输出中脱敏。

普通检查不调用文本模型、不读取真实候选人档案。原生解码测试需已安装并校验通过的语音模型，否则明确跳过。外部服务测试由开发者显式启用。

## 可选 Codex 检查

先安装并登录 Codex。连接检查：

```bash
swift run CodexConnectionCheck
```

以下操作会发送合成文本，使用当前 Codex 账号额度：

```bash
swift run CodexConnectionCheck --run
swift run CodexConnectionCheck --cleanup
swift run CodexConnectionCheck --review
```

自定义路径使用环境变量 `COPILOT_CODEX_PATH`。应用的路径偏好与命令行诊断独立。

## 本地语音诊断

```bash
swift run -c release ASRCheck --install
swift run -c release ASRCheck --repeat /path/hr.wav /path/candidate.wav
```

输入为 24 kHz、单声道 PCM WAV。使用合成音频；`--expect-silence` 用于静音输入检查。

## 人工验收

按 [界面验收流程](GUI-ACCEPTANCE.md) 操作。测试记录只写系统、版本、步骤和实际结果，不附真实候选人材料或存档。
