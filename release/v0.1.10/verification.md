# Lives 0.1.10 发布验证

日期：2026-08-30。测试机：Apple Silicon / macOS 27.0（26A5421a）。

## 自动化与构建

- `npx tsc -b`（前端类型检查）与 `npm test`：前端 58 项全部通过（含多画格独立关键帧、自定义比例边界等新增用例）。
- `swift build` 与 `swift test`：原生全部测试通过（模板裁剪、画格布局、导出配对、更新链路等）。
- `scripts/verify-photo-permissions.py`：主程序与照片辅助程序的照片库 entitlement 检查通过。

## 本轮真机证据与边界

- 照片权限恢复链路重构：应用内“重新授权并保存”执行 4 条 `tccutil reset`（照片辅助程序 + 主程序 × PhotosAdd + Photos），并以全新辅助进程轮询授权状态（最长约 3 分钟）；恢复过程与授权弹窗行为全部记录在 `~/Library/Logs/Lives/photo-reset.log`。
- 诊断插桩：授权流程记录进入状态、系统弹窗调用与回调耗时；若系统未弹窗即自动拒绝（回调 <2 秒返回 denied），返回 `PHOTO_PERMISSION_PROMPT_SUPPRESSED` 并引导“复制修复命令”。
- 重置动作已串行化并支持取消，消除了此前日志中出现的并发重置与潜在双重导出。
- 拒绝后的恢复卡片提供“复制修复命令”（写入剪贴板，无需额外权限）与“改存到文件夹”两条出路；连续 2 次拒绝后主按钮渐进降级为“改存到文件夹”。
- 待真机回归：拒绝 → 应用内恢复 → 弹窗重现 → 允许保存的完整闭环需在新安装包上人工确认（含 TCC.db 快照对照）；自动化无法代替 GUI 授权操作。

## 冻结安装包

- 最终 DMG：`Lives_0.1.10_aarch64.dmg`
- SHA-256：`edef46248d88d4342a9bc18158bfc204dd607f51e6bea9d2527238fc184a70e4`
- Apple 公证：App `da2cfdb4-ae93-41ea-9dad-09d21f78a990`，DMG `fbd9cb99-13b7-436e-ba28-752177077fbb`，均为 `Accepted`，并已钉入票据。
- 构建脚本 PASS 7 已通过 `spctl`，结果为 `accepted / source=Notarized Developer ID`。
- 本次未重新完成 macOS 13/14、所有导出模板、真实图库写入、iCloud 与 iPhone 回归；不把自动化或签名验证等同于这些验收。
