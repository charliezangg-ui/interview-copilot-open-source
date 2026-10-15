# 参与开发

通过 Issues 描述问题，通过 Pull Request 提交改动。先说明触发步骤和预期行为，再描述实现。

## 本地检查

需要 macOS 15+、完整 Xcode 和 Python 3：

```bash
bash scripts/doctor.sh
bash scripts/check.sh
bash scripts/scan-secrets.sh
```

普通测试使用临时目录及合成材料，不需要 Codex、飞书账号或模型调用费用。原生解码测试需要语音模型；真实服务检查需显式启用，见 [测试说明](docs/VALIDATION.md)。

## 提交要求

- 一个改动聚焦一个问题，并说明测试结果。
- 不提交真实简历、录音、会话存档、凭据、签名私钥或公司内部资料。
- 数据结构兼容旧存档；提示词保持独立初评与面试官判断隔离。
- 新增依赖说明用途及许可证，更新第三方声明。
- 提交的代码须有权以本项目 MIT 许可证分发。

提交前检查实际 diff。敏感信息误提交时，先撤销暴露的凭据，再清理历史。安全问题按 [SECURITY.md](SECURITY.md) 处理。
