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

本文件将在 GitHub Release、官网 Pages 和自有下载源同步完成后补充线上资产、下载哈希及 workflow 结果。
