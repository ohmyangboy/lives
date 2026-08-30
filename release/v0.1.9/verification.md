# Lives 0.1.9 发布验证

日期：2026-08-30。测试机：Apple Silicon / macOS 27.0（26A5421a）。

## 自动化与构建

- `npm test`：44 项通过。
- `npm run build`、官网 `npm run build`：通过。
- 原生方向回归测试：`testCoverContextRectPreservesTopToBottomImageOrientation` 通过；完整 `swift test` 在发布构建前通过 26 项，3 项因缺少外部素材跳过。
- 多画格关键帧状态：前端 `src/domain.test.ts` 验证每个画格携带独立关键帧，原生封面合成按画格时间取帧。

## 本轮真机证据与边界

- 修复测试阶段已实际触发 macOS“仅添加照片”授权弹窗，系统日志记录用户允许并创建 PhotosAdd 授权记录。
- 安装提示背景、Applications 链接、640 × 440 窗口和图标位置已通过只读挂载后的 Finder `.DS_Store` 检查。
- 未重新执行干净用户的完整安装流程、macOS 13/14 兼容矩阵、全部模板、真实图库写入、iCloud 与 iPhone 回归；不把自动化或签名验证等同于这些验收。

## 冻结安装包

- 最终 DMG：`Lives_0.1.9_aarch64.dmg`
- SHA-256：`c6a58a0b829a9d281e31b4d083fe5ac7b4359afb74b288dfa3a3e0cfea3c9244`
- Apple 公证：App `0221ba14-df64-4598-a50d-705274fc71cd`，DMG `331020fb-c479-4792-b2e5-5848006c29b2`，均为 `Accepted`，并已钉入票据。
- 构建脚本 PASS 7 已通过 `spctl`，结果为 `accepted / source=Notarized Developer ID`。
- 本次未重新完成 macOS 13/14、所有导出模板、真实图库写入、iCloud 与 iPhone 回归；不把自动化或签名验证等同于这些验收。
