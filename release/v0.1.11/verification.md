# Lives 0.1.11 发布验证

日期：2026-08-30。测试机：Apple Silicon / macOS 27.0（26A5421a）。

## 自动化与构建

- `npx tsc -b`（前端类型检查）与 `npm test`：前端 58 项全部通过。
- `swift build` 与 `swift test`：原生全部测试通过。
- `scripts/verify-photo-permissions.py`：主程序与照片辅助程序的照片库 entitlement 检查通过。

## 本轮真机证据与边界

- 反馈设备信息改为原生采集：新增 `systemDiagnostics` 动作（ProcessInfo + sysctl + NSScreen），与本机实测一致——`Apple M2 (arm64)`、`macOS 27.0.0 (26A5421a)`、`Mac14,2`、24 GB、主显示器 `1470 × 956 (@2x)`、`zh_CN`；彻底替换 WebView 的 `MacIntel` / Intel Mac 假 User Agent。「关于」对话框、反馈邮件与 GitHub Issue 链路全部切换。
- 更新重启后的反馈提示：更新安装前写入 `lives.postUpdateFeedbackPending` 标记，新实例首次启动弹出"已更新 + 反馈入口"卡片，展示后即清除（每次更新一次）。
- 照片权限恢复链路收尾：授权状态统一由全新辅助进程（`photo-status`）读取，重置动作经 `PhotoResetGate` 串行化、支持取消（`CancellationRegistry`），前端 token 防护避免取消后残留回调二次导出。
- 待真机回归：照片权限"拒绝 → 应用内恢复 → 弹窗重现 → 允许保存"的完整闭环仍需按发布说明在新包上人工确认（含 TCC.db 快照对照）。

## 冻结安装包

- 最终 DMG：`Lives_0.1.11_aarch64.dmg`
- SHA-256：`e2d24497a0ed7fa4c9ee6e681e236ef81ec3efcd22f0495b0405b35e72c1bb3b`
- Apple 公证：App `0d619e60-f32d-4da7-8d10-c0a8244660ae`，DMG `2bd91be1-3054-401b-bd57-1a2ad2716f07`，均为 `Accepted`，并已钉入票据。
- 构建脚本 PASS 7 已通过 `spctl`，结果为 `accepted / source=Notarized Developer ID`。
- `scripts/build-dmg.py` 新增构建前冲突挂载清理：手动挂载的旧版 DMG（卷名同为 "Lives"）不再导致 create-dmg exit 16。
- 本次未重新完成 macOS 13/14、所有导出模板、真实图库写入、iCloud 与 iPhone 回归；不把自动化或签名验证等同于这些验收。
