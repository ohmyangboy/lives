# Lives 0.1.1

这是 Lives 的首个体验优化版本，适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高的正式版本。

## 本次更新

- 修复竖屏视频在时间线缩略图中被横向拉伸的问题。
- 修复全屏预览时全屏按钮和顶部提示文案被窗口边缘遮挡的问题。
- 优化 Live Photo 预览：视频播放结束后柔和渐变回关键帧，不再直接跳转。
- 官网改用真实软件截图与脱敏演示视频，并完善功能介绍、隐私说明、联系方式和移动端排版。

## 隐私

视频处理在 Mac 本机完成。Lives 只引用原文件，不上传、复制或修改素材；0.1.1 不包含账号、广告、行为分析或自动崩溃上报。

## 安装前请了解

此版本使用 ad-hoc 签名，尚未经过 Apple Developer ID 签名或 Apple 公证，也没有应用内自动更新。macOS 首次打开时可能提示无法验证开发者。请只从官方 Release 下载并核对 SHA-256；如系统拦截，请按照 [Apple 官方说明](https://support.apple.com/zh-cn/102445)决定是否打开，不要关闭 Gatekeeper。

macOS Beta 或开发者预览版可能缺少或暂时禁用系统视频编码器，导致无法生成 Live Photo，因此不属于 0.1.1 的支持范围。

## 文件校验

```text
391cfa66fd1567b1a8ebbad85b397114fe0eea97088dde515556bfc9da3caf70  Lives_0.1.1_aarch64.dmg
```

问题反馈请通过 [GitHub Issues](https://github.com/ohmyangboy/lives/issues) 或官网支持邮箱联系。
