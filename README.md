# Lives MVP

Lives 是一个 macOS 本地工具：从多个 MOV/MP4/M4V 素材中截取不同的 3 秒瞬间，拼贴为一张 Live Photo，并保存到 Apple“照片”或指定文件夹。

当前正式版为 [`0.1.9`](https://github.com/ohmyangboy/lives/releases/tag/v0.1.9)。本版修复封面照片方向、支持多画格独立关键帧，并保留 0.1.8 的照片授权和安装修复。完整的产品范围、实现状态、验收门槛和技术约束请从 [docs/项目文档](docs/项目文档/README.md) 开始阅读：



- [PRD](docs/项目文档/PRD-MVP.md)
- [开发计划与验收清单](docs/项目文档/开发计划与验收清单.md)
- [技术现状与架构](docs/项目文档/技术现状与架构.md)

## 安装 0.1.9

1. 从 [v0.1.9 发布页](https://github.com/ohmyangboy/lives/releases/tag/v0.1.9)下载 Apple Silicon DMG，核对同页的 SHA-256。
2. 退出旧版，将 Lives 拖入“应用程序”文件夹。
3. 从“应用程序”打开 Lives，不要直接在 DMG 安装窗口运行；保存到“照片”时按提示允许“仅添加照片”。

可从发布页下载安装，或通过应用内自动更新升级。详见 [本版更新说明](release/v0.1.9/release-notes.md)与[验证记录](release/v0.1.9/verification.md)。

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
bash scripts/test-photo-signing.sh
npm run tauri:build
```

## 真机验收与发布

代码级自动测试不能替代平台链路验证。当前的历史验收记录在 [docs/真机验收记录.md](docs/真机验收记录.md)，新的发布检查以 [开发计划与验收清单](docs/项目文档/开发计划与验收清单.md) 为准。

发布版本已配置 **Developer ID Application: Yonghao Yang (LGKLTGNTY2)** 签名，并通过 **Apple 官方公证（Notarized & Stapled）**。安装包与校验和发布于 [GitHub Releases](https://github.com/ohmyangboy/lives/releases)。官网位于 [https://ohmyangboy.github.io/lives/](https://ohmyangboy.github.io/lives/)。

## 应用内自动更新

应用内置自动更新：冷启动静默检查 GitHub 最新正式版本 → 后台流式下载 + SHA-256 校验 → 标题栏胶囊展示进度 → 一键「重启」原子换包并进入新版本。要点：

- 换包采用同卷 rename 原子替换（失败自动回滚旧版本），跨卷降级 `ditto`，主目录不可写时兜底安装到 `~/Applications`；
- 重启后校验新进程真实运行，失败逐级降级（`open` 重试 → 直接拉起主程序）；
- 检查/下载/退出均有看门狗超时，任何状态必然收尾，不会永久转圈；
- 更新中断自动恢复：已下载未安装的更新在下次冷启动直接提示完成安装；
- 替换过程全程记录于 `~/Library/Caches/com.yangbukun.lives/Updates/relaunch.log`，排查「重启卡住」类问题以该日志为准。
