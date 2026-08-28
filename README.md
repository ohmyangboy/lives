# Lives MVP

Lives 是一个 macOS 本地工具：选择 1～3 段 MOV/MP4/M4V 视频，为每段选择连续 3 秒，以多种拼贴模板生成 Live Photo，并保存到 Apple“照片”或指定文件夹。

## 已实现

- 视频选择与 Finder 拖放，格式、时长和数量校验；
- 单画面、二拼和三拼模板；
- 每个素材独立的 3 秒选段与 0.1 秒步进；
- Canvas 循环预览、格子切换和裁剪中心拖动；
- Swift/AVFoundation H.264 多轨合成；
- JPEG 与 MOV 内容标识、still-image-time 元数据；
- `PHLivePhoto.request` 保存前校验；
- PhotoKit `.photo` + `.pairedVideo` 保存，以及 `.photoLive` 回查；
- 权限拒绝、取消、错误反馈和任务临时目录清理；
- 浏览器预览模式（不能写入“照片”）。

## 开发运行

需要 Xcode、Node.js 和 Rust。首次安装依赖后：

```bash
npm install
npm run tauri:dev
```

网页预览：

```bash
npm run dev
```

测试与构建：

```bash
npm test
swift test --package-path native/LivePhotoService
npm run tauri:build
```

## 真机验收

代码级自动测试不能替代平台链路验证。发布前至少完成：Mac“照片”显示一个 Live 资产并可播放；iCloud 同步到 iPhone 后保持 Live；在记录版本号的小红书 iOS App 中可选择、发布并回看。详见 [docs/真机验收记录.md](docs/真机验收记录.md)。

当前构建使用 ad-hoc 签名，未配置 Developer ID、公证或 App Sandbox，仅适合本机开发与内部测试。发布前应改用 Developer ID 签名并完成公证；如计划进入 Mac App Store，需要把 Swift 媒体层改为带独立 entitlement 的 XPC helper 后再启用 App Sandbox。
