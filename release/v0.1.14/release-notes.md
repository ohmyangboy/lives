# Lives 0.1.14

正式版，适用于 Apple Silicon Mac，最低系统要求为 macOS 13。

## 本次更新

- 修复 4K H.264 视频导入后预览画面黑屏的问题。
- 导入超过 1920 像素的高清视频时，由 macOS 原生媒体框架生成 WebView 可播放的预览代理；原始视频路径保持不变，后续导出仍使用原始素材。
- 预览代理按源文件路径、大小和修改时间缓存，重复打开素材时复用；普通分辨率视频不额外转码。
- 保留自有更新源优先、GitHub 备用、安装包大小与 SHA-256 校验、Developer ID 签名身份验证和照片权限恢复等既有功能。

## 安装

下载本页的 `Lives_0.1.14_aarch64.dmg`，核对 `.sha256` 文件，退出旧版后将 Lives 拖入“应用程序”。也可以通过应用内更新升级。

本版使用 Developer ID 签名并完成 Apple 公证与票据封装。

## 验证范围

前端自动化测试、Swift 原生测试、4K 视频预览回归、官网构建及生产打包均纳入本次发布验证。完整的 0.1.13 → 0.1.14 真机安装重启，以及 macOS 13/14、全部导出模板、iCloud 与 iPhone 回归仍待验收；不以构建或单测代替真机验证。

[官网更新日志](https://ohmyangboy.github.io/lives/changelog.html) · [问题反馈](https://github.com/ohmyangboy/lives/issues)
