# Lives

> **Lives in lives** —— 在 Mac 上，把视频里的多个瞬间，拼成一张真正的 Live Photo。

[![Downloads](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdownload.1leaf.cc%2Flives-download-stats.json&query=%24.downloads&label=downloads&color=brightgreen)](https://github.com/ohmyangboy/lives/releases)
[![App Store](https://img.shields.io/badge/App_Store-Lives_Mobile-0D96F6?style=flat-square&logo=apple&logoColor=white)](https://apps.apple.com/app/id6807655743)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B%20%C2%B7%20Apple%20Silicon-blue?style=flat-square)](https://github.com/ohmyangboy/lives/releases)
[![License](https://img.shields.io/badge/license-GPLv3-c92a2a?style=flat-square)](LICENSE)

[English](README_EN.md) · [简体中文](README.md) · [产品官网](https://lives.1leaf.cc/) · [GitHub Pages 镜像](https://ohmyangboy.github.io/lives/) · [GitHub Releases](https://github.com/ohmyangboy/lives/releases) · [移动端官网](https://ohmyangboy.github.io/lives-mobile-website/)

---

## 产品简介

Lives 是一款专为实况照片拼贴打造的工具，提供 macOS 原生桌面端与 iOS 移动端支持：

- **macOS 版（Lives Mac）**：**完全开源免费**。macOS 原生的视频转 iPhone Live Photo 工具。从多个 MOV/MP4/M4V 素材中自由截取片段，调节 1–15 秒实况时长，支持关键帧精准控制，一键同步至 Apple“照片”，全程 100% 本地处理。
- **iOS 版（Lives Mobile）**：**基础功能全部开放，仅 Pro 功能可以一次性买断（如果能支持下 Pro 计划再好不过了！）**。面向 iOS 的视频转 Live 拼图工具，任意视频都能按你想要的方式拼贴组合，拼出你的生活瞬间。现已正式上线 App Store。

![Lives 完整编辑界面：左侧视频素材库、中间三拼画布、右侧拼贴设置和底部时间线](website/src/assets/lives-editor-home.jpg)

> 界面录制自真实 Lives 运行环境，仅使用公开测试素材，不包含用户视频或个人信息。

---

## 核心理念

- 🔒 **100% 本地处理**：原文件本地解码，无需上传云端，素材始终留在本机；无账号、无云端素材库。
- ⏱️ **1–15 秒自由调节**：每格独立截取选段，支持胶卷与观片器关键帧控制，播放结束柔和回归关键帧。
- 📐 **8 × 5 自由组合**：8 种预置布局（上下、左右、三拼、大小画面等）× 5 种场景比例（9:16、3:4、1:1、4:3、16:9）。
- 📷 **真正的 Live Photo**：生成带有配对元数据的 JPEG 与 MOV，作为原生 Live Photo 资产写入照片库，通过 iCloud 照片保留完整实况动态效果。

---

## 工作流：只做三件事

不需要学习复杂的专业剪辑软件，素材、画布和时间线始终在同一个窗口内完成：

1. **挑（PICK）**：导入多个视频或一个文件夹，选择片段并拖动时间线手柄，将 Live 时长调节为 1–15 秒。
2. **拼（COLLAGE）**：把素材拖入画格。单个视频也可重复使用并截取不同瞬间；每个画格均可独立选段、缩放、移动和开关原声。
3. **动（MOTION）**：设定 Live Photo 封面关键帧和声音，预览同步效果；一键保存到 Apple“照片”，或导出 JPG + MOV 配对文件。

---

## 下载与获取

### iOS 版（Lives Mobile 已正式上线）

iOS 移动端 **Lives Mobile** 现已正式上架 App Store！

> 💡 **版本与说明**：macOS 开源免费；iOS 基础功能全部开放，仅 Pro 功能可以一次性买断（能支持下 Pro 计划再好不过了！）。

- 📲 **App Store 页面**：[在 App Store 下载 Lives Mobile](https://apps.apple.com/app/id6807655743)
- 🌐 **移动端官网**：[访问 Lives Mobile 官网](https://ohmyangboy.github.io/lives-mobile-website/)

<a href="https://apps.apple.com/app/id6807655743" target="_blank" title="前往 App Store 下载 Lives Mobile">
  <img src="assets/lives-mobile-app-store-qr.png" alt="Lives Mobile App Store 下载二维码" width="160" />
</a>

*使用 iPhone 扫描上方二维码或点击图片即可直接跳转至 App Store 下载。*

---

### macOS 版安装与升级

当前 macOS 正式版为 [`0.1.16`](https://github.com/ohmyangboy/lives/releases/tag/v0.1.16)。本版加入胶卷与观片器关键帧控制、1–15 秒时长调节及短素材末帧补齐，Mac 应用与标题栏图标统一为官网黑金版本，在反馈面板加入 Lives Mobile 下载二维码与官网入口。

#### 三步安装
1. **下载 DMG**：从 [v0.1.16 发布页](https://github.com/ohmyangboy/lives/releases/tag/v0.1.16)下载 Apple Silicon DMG，核对同页的 SHA-256 校验和。
2. **拖入“应用程序”**：打开 DMG，将 Lives 拖入“应用程序”文件夹。
3. **运行与授权**：退出旧版，从“应用程序”打开 Lives（不要直接在 DMG 窗口运行）；首次保存到“照片”时，按系统提示允许“仅添加照片”。

详见 [本版更新说明](docs/releases/0.1.16.md) 与 [发布验证记录](docs/releases/0.1.16-verification.md)。

#### 签名、公证与安全
- 发布版本已配置 **Developer ID Application: Yonghao Yang (LGKLTGNTY2)** 签名，并通过 **Apple 官方公证（Notarized & Stapled）**。
- 唯一官方发布源为 [GitHub Releases](https://github.com/ohmyangboy/lives/releases)，请勿从第三方渠道下载。

#### 应用内自动更新
Lives 内置可靠的自动更新机制：
- **双源检测**：冷启动优先检查自有更新源（GitHub 备用）。
- **后台校验**：后台静默下载，严格校验文件大小、SHA-256 与应用签名身份，标题栏胶囊实时展示进度。
- **原子替换**：同卷 rename 原子替换（失败自动回滚旧版本），跨卷降级 `ditto`，主目录不可写时兜底至 `~/Applications`。
- **看门狗保障**：检查、下载和退出过程均有超时看门狗保护，确保状态必然收尾。
- **诊断日志**：替换过程全程记录于 `~/Library/Caches/com.yangbukun.lives/Updates/relaunch.log`。

---

## 本地与隐私承诺

**本地，就是边界。**
- **零云端上传**：原文件直接本地解码，不上传、不修改源视频，无账号、无云端素材库。
- **最小权限**：仅在选择“保存到照片”时请求“仅添加照片”权限，不读取整个图库。
- **无追踪**：不包含任何商业广告、用户行为分析或静默崩溃上报。
- **干净清理**：操作完成或退出时自动清理处理过程中的临时文件。

[阅读完整隐私说明](https://ohmyangboy.github.io/lives/privacy.html)

---

## 仓库结构与项目文档

### 项目文档
- [PRD 需求文档](docs/项目文档/PRD-MVP.md)
- [开发计划与验收清单](docs/项目文档/开发计划与验收清单.md)
- [技术现状与架构](docs/项目文档/技术现状与架构.md)
- [真机验收记录](docs/真机验收记录.md)

### 仓库目录
本仓库同时承载 Mac 应用源码与官网源码。核心引擎位于 `packages/LivesCore`，是本仓库内部模块，不独立发版：
- `src/`：React / TypeScript 客户端界面
- `src-tauri/`：Rust 宿主与原生桥接
- `native/LivePhotoService/`：Swift Helper（负责照片库写入与底层合成链路）
- `packages/LivesCore/`：媒体处理、模型与渲染引擎
- `website/`：官网源码（[lives.1leaf.cc](https://lives.1leaf.cc/)）
- `release/`：历史版本的更新说明、验证记录与校验和
- `docs/`：开发、发布与许可参考；`.agents/rules/`：发布与 Actions 规则

---

## 开发与构建

需要 Xcode、Node.js（v18+）与 Rust（1.80+）。首次安装依赖后：

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
npm test                                              # 前端 Vitest
swift test --package-path packages/LivesCore           # 内部 Core 测试
swift test --package-path native/LivePhotoService      # Swift Helper 测试
bash scripts/test-photo-signing.sh                    # 签名与链路测试
npm run tauri:build                                   # 生产构建
npm run website:build                                 # 官网构建
```

---

## 反馈与支持

- **公开反馈**：适合 Bug 报告与功能建议，请前往 [GitHub Issues](https://github.com/ohmyangboy/lives/issues/new/choose)（提交前请勿上传私人视频、个人信息或未脱敏日志）。
- **邮件联系**：适合私人信息或安全漏洞反馈，请发送至 [ohmyangboy@gmail.com](mailto:ohmyangboy@gmail.com)。
- **微信赞赏**：Lives 是独立开发并开源的软件。如果它帮你留住了一个瞬间，欢迎通过微信赞赏支持开发者的持续投入与维护：

<img src="website/src/assets/wechat-sponsor-qr.jpg" alt="微信赞赏码" width="160" />

---

## 许可与声明

- **macOS 版**：源码采用 [GNU General Public License v3.0](LICENSE)（GPL-3.0-only）完全开源免费。历史公开版本的既有授权不撤回；第三方组件继续适用各自许可，详见 [许可边界](LICENSING.md) 与 [第三方声明](THIRD_PARTY_NOTICES.md)。
- **iOS 版**：基础功能全部开放使用，进阶 Pro 功能提供一次性买断。

*Live Photos is a trademark of Apple Inc. Lives 与 Apple Inc. 无隶属或背书关系。*
