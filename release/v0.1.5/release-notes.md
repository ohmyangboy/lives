# Lives 0.1.5

适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高的正式版本。推荐所有用户升级。

## 更新要点

- **应用内自动检查与静默更新**：
  - 支持冷启动静默检查与后台自动流式下载最新版本；
  - 标题栏无感胶囊组件实时展示下载百分比与解压进度；
  - 下载完成后一键点击“重启”，自动完成安全原子替换与无缝重启到最新版本；
  - 应用菜单中增加“检查更新...”手动检查入口与状态反馈。
- **原生更新引擎升级**：
  - 基于 Swift 原生网络与系统工具链实现实时 SHA256 完整性校验、DMG 静默挂载与应用提取；
  - 优化更新进程隔离与权限处理，确保安装与重启安全可靠。
- **Apple Developer ID 官方签名**：
  - 完整签署官方 Developer ID 证书并完成 Hardened Runtime 代码签名与本地门禁评估。

## 文件校验

`Lives_0.1.5_aarch64.dmg`

`de80543afde29a29f11427583cd35986952944d2eb64e4ba3b99e73c62dbba2d`

---

# Lives 0.1.5

For Apple Silicon Mac, requires macOS 13 Ventura or higher. Recommended for all users.

## Key Updates

- **In-App Auto Check & Silent Updates**:
  - Supports silent update checks on cold boot and background streaming download;
  - Non-intrusive titlebar capsule displays real-time download percentage and extraction progress;
  - One-click "Restart" button once ready, performing atomic replacement and relaunch seamlessly;
  - Added "Check for Updates..." entry in the application menu with instant status feedback.
- **Native Update Engine Upgrade**:
  - Real-time SHA-256 integrity verification, silent DMG mounting, and staged app extraction based on native Swift toolchain;
  - Robust process replacement script ensuring smooth and secure updates.
- **Apple Developer ID Code Signing**:
  - Fully signed with Developer ID certificate and Hardened Runtime verification.

## Checksums

`Lives_0.1.5_aarch64.dmg`

`de80543afde29a29f11427583cd35986952944d2eb64e4ba3b99e73c62dbba2d`

