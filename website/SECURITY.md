# Lives 安全政策

## 受支持版本

| 版本 | 状态 |
| --- | --- |
| 0.1.x (含 0.1.6) | 正式版，接受安全报告 |
| 更早的内部构建 | 不支持，请升级到最新公开版本 |

Lives 0.1.6 已使用 Apple Developer ID 签名（Developer ID Application: Yonghao Yang）。请只从 [ohmyangboy/lives Releases](https://github.com/ohmyangboy/lives/releases) 下载，并核对发布页提供的 SHA-256。



## 私密报告安全问题

请不要在公开 Issue 中披露漏洞、利用步骤、私人影像、完整本地路径、Apple ID、访问令牌或未经脱敏的日志。

请发送邮件至 **ohmyangboy@gmail.com**，主题使用：

```text
[Lives 安全] 问题摘要
```

邮件建议包含：

- 受影响的 Lives 版本、macOS 版本和 Mac 芯片；
- 问题影响及最小复现步骤；
- 已脱敏的截图或日志；
- 是否已经对外披露；
- 方便联系的邮箱。

Lives 由个人维护，不提供 7×24 小时响应或固定修复时限。收到报告后会尽力在 7 天内确认，并根据影响范围同步评估与处理进度。未经双方同意，请在修复版本发布前避免公开漏洞细节。

## 安全发布原则

- 不覆盖已经发布的安装包；修复使用更高版本号。
- 安全修复仍通过官方 GitHub Release 分发并提供新的 SHA-256。
- 不要求用户关闭 Gatekeeper，也不提供移除 quarantine 属性的绕过命令。
- 如果发现 Release 资产可能被篡改，会优先暂停下载入口并在仓库发布说明。
