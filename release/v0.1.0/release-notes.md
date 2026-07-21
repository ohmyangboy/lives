# Lives 0.1.0

首个独立分发预览版。适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高版本。

## 主要功能

- 从多个 MOV、MP4、M4V 视频或文件夹建立本地素材库。
- 同一素材可重复放入不同画格，并分别截取连续 3 秒。
- 提供 8 种拼贴模板和 5 种画面比例，支持横竖屏切换。
- 每个画格可独立移动、缩放、清除和开关原声。
- 可设置 Live 关键帧；预览播放结束后停在该关键帧。
- 保存到 Apple“照片”时只请求添加权限，或导出 JPG + MOV 配对文件到指定文件夹。

## 隐私

视频处理在 Mac 本机完成。Lives 只引用原文件，不上传、复制或修改素材；0.1.0 不包含账号、广告、行为分析或自动崩溃上报。

## 安装前请了解

此版本使用 ad-hoc 签名，尚未经过 Apple Developer ID 签名或 Apple 公证，也没有应用内自动更新。macOS 首次打开时可能提示无法验证开发者。请只从官方 Release 下载并核对 SHA-256；如系统拦截，请按照 [Apple 官方说明](https://support.apple.com/zh-cn/102445)决定是否打开，不要关闭 Gatekeeper。

## 文件校验

```text
ea6dba1f4e54c55949c5afe0d0c8d994efa6f9f8cb871bcfebf068741a357d2c  Lives_0.1.0_aarch64.dmg
```
