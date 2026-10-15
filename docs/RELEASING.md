# GitHub 发布流程

项目通过 GitHub 源码与 Releases 分发，不走 App Store。

## 源码发布

1. 核对 LICENSE 版权主体、第三方声明、应用版本和 CHANGELOG。
2. 运行 `bash scripts/check.sh` 与 `bash scripts/scan-secrets.sh`。
3. 运行 `python3 scripts/export-source.py`，检查 `dist/source/` 中的源码包和 SHA-256。
4. 在独立目录解压并验证文件清单，按安装说明构建。
5. 将审核后的源码纳入公开仓库，提交后等待 CI 通过，再创建与应用版本一致的 `v<版本>` 标签。
6. 标签工作流重新检查并创建 Release 草稿。核对附件、更新说明后发布。

首次从个人开发仓库迁出时，使用源码导出包初始化干净仓库。不要直接把含内部验收记录的旧 Git 历史设为公开；保留原仓库作开发备份，保留必要的第三方归属说明。

解压后可在源码根目录验证：

```bash
shasum -a 256 -c SOURCE_MANIFEST.sha256
bash scripts/check.sh
```

GitHub 设置建议开启 Issues、私密漏洞报告，并将源码检查和 Swift 测试设为合并要求。工作流采用只读默认权限；只有标签发布草稿的任务使用 contents:write，不在 PR 检查中使用签名或个人账号凭据。

## 可下载应用包

源码发布后，可通过 Developer ID 签名和 Apple 公证提供安装包。需要维护者自己的 Apple Developer Program 账号与 Developer ID Application 证书；本机开发证书不作为公开分发身份。

在当前版本源码目录构建独立输出：

```bash
COPILOT_SIGNING_IDENTITY='Developer ID Application: 你的证书名称' \
COPILOT_DISTRIBUTION=1 \
COPILOT_APP_OUTPUT=dist/distribution/InterviewCopilot.app \
bash scripts/build-app.sh
```

脚本启用 Hardened Runtime、时间戳和麦克风 entitlement，并检查 Developer ID 身份。完成公证并打包：

```bash
bash scripts/package-release.sh dist/distribution/InterviewCopilot.app '你的公证钥匙串配置名'
```

公证使用 `notarytool` 的钥匙串配置名；在本机配置凭据，不将密码、私钥或证书导出提交仓库。脚本等公证通过后装订票据，再生成 ZIP 和 SHA-256；失败不会输出最终安装包。

发布前在另一台 Mac 验证下载、首次启动、权限和旧存档恢复，明确标注实际构建的芯片架构。普通 Release 编译不等于两个架构都已验证。安装包中应包含项目许可证及第三方声明。

签名、公证和更新身份参考 [Apple Developer ID](https://developer.apple.com/developer-id/)。首个公开包确定应用标识和签名身份后持续复用；切换身份时处理授权迁移。
