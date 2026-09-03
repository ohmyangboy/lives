# Lives 0.1.14 发布验证

日期：2026-09-03。

## 功能与自动化

- 修复 4K H.264 视频导入后的 WebView 黑屏预览：真实 `3840×2160` 素材可生成可播放预览代理，代理最大边长不超过 `1920`，首帧可提取，并验证了缓存复用。
- 前端测试：`66` 项通过。
- Swift 原生全量测试：`32` 项通过，`4` 项因未提供外部素材跳过，`0` 失败。
- TypeScript 生产构建与官网构建通过；无未替换的官网版本占位符。

## 版本一致性

- App：`0.1.14`，Bundle ID `com.yangbukun.lives`，架构 `arm64`。
- 照片 Helper：`0.1.14`，Bundle ID `com.yangbukun.lives.photos-helper`。
- Rust/Tauri/前端版本源已统一为 `0.1.14`。

## 签名与公证

- 完整代码签名、照片权限签名检查及 Gatekeeper 验证通过，身份为 `Developer ID Application: Yonghao Yang (LGKLTGNTY2)`。
- App 公证：`2434684b-bc9d-4224-9c59-f0fccd00241c`，`Accepted`，票据已封装并验证。
- DMG 公证：`b92cddde-1413-4ae7-a2a5-e4101dcc1956`，`Accepted`，票据已封装并验证。
- Gatekeeper：`Lives.app: accepted`，来源为 `Notarized Developer ID`。
- DMG：`Lives_0.1.14_aarch64.dmg`，大小 `11648552` 字节。
- SHA-256：`c988f3ea7a00703eea2e287c0d7c9a1068fe749db5779e4a2c13e884f3df244f`。
- `hdiutil verify` 和 DMG `stapler validate` 均通过。

## 人工验收边界

完整的 0.1.13 → 0.1.14 真机安装重启、当前 VPN 与用户自行关闭 VPN 后的网络表现、macOS 13/14、所有导出模板及 iCloud/iPhone 回归仍待验收。自动化与构建成功不代表这些场景已经完成。

## 发布后验证

- 实现提交：`5fbab0c`，正式标签 `v0.1.14`。
- [GitHub Release](https://github.com/ohmyangboy/lives/releases/tag/v0.1.14) 已发布为正式版并标记为最新版本，包含 DMG 与 `.sha256` 资产。
- [官网部署 workflow](https://github.com/ohmyangboy/lives/actions/runs/33749025980) 成功；GitHub Pages 构建、Pages 部署和 1leaf 官网部署均成功。
- [自有源同步 workflow](https://github.com/ohmyangboy/lives/actions/runs/33749100629) 成功；GitHub Release 资产下载和 SHA-256 校验通过后写入 `Lives-latest.dmg`。
- `https://lives.1leaf.cc/`、`https://ohmyangboy.github.io/lives/` 的首页版本均为 `0.1.14`，更新日志均包含 4K 预览修复说明。
- 自有更新清单 `https://download.1leaf.cc/lives-download-stats.json` 返回 `currentVersion=v0.1.14`、大小 `11648552` 字节、SHA-256 与正式 DMG 一致，`updatedAt=2026-09-03T11:21:48Z`。
- 从自有源重新下载 `Lives-latest.dmg`，HTTP 200，大小 `11648552` 字节，SHA-256 与本地及 GitHub Release 一致。
