# Lives 0.1.7

适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高的正式版本。推荐所有用户升级。

## 更新要点

- **应用内自动更新与一键重启安装修复**：
  - 修复点击“重启”无响应的问题，解耦 RPC 与后台替换脚本时序；
  - 优化重启替换脚本逻辑，主进程安全退出后自动原子替换并唤起最新版；
  - 完善应用路径定位机制，兼容各类安装目录。
- **Apple Developer ID 官方签名与公证**：
  - 完整签署 Developer ID 证书并通过 Apple Notary 官方公证（Notarized & Stapled）。

## 文件校验

`Lives_0.1.7_aarch64.dmg`

`dbed9e4c612108944812708ec63d79f29f0be645133f201fe558978196d144c6`

---

# Lives 0.1.7

For Apple Silicon Mac, requires macOS 13 Ventura or higher. Recommended for all users.

## Key Updates

- **In-App Auto Update & One-Click Restart Fix**:
  - Fixed an issue where clicking "Restart" did not trigger the app relaunch;
  - Decoupled native RPC response from background atomic replacement script;
  - Enhanced outer app bundle location resolution and safe process exit flow.
- **Apple Developer ID Code Signing & Notarization**:
  - Fully signed with Developer ID certificate and notarized & stapled by Apple Notary service.

## Checksums

`Lives_0.1.7_aarch64.dmg`

`dbed9e4c612108944812708ec63d79f29f0be645133f201fe558978196d144c6`
