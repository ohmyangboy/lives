# Lives 0.1.8 发布验证

日期：2026-08-30。测试机：Apple Silicon / macOS 27.0（26A5421a）。

## 自动化与构建

- `npm test`：44 项通过。
- `npm run build`、官网 `npm run build`：通过。
- 原生 `swift test`：26 项，0 失败，3 项因缺少外部素材跳过；包括照片错误分类、beta 到正式版的版本比较及渲染回归。
- `bash scripts/test-photo-signing.sh`：真实签名探针通过；缺少照片 entitlement 时被拦截，包含时通过，不调用图库授权。
- 多画格独立关键帧回归：前端 `src/domain.test.ts` 验证每个画格携带不同关键帧，原生封面合成按每个画格的时间取帧。
- 所有应用版本配置统一为 `0.1.8`；稳定版下载与自动更新使用 GitHub 正式 Release。

## 本轮真机证据与边界

- 修复测试阶段已实际触发 macOS“仅添加照片”授权弹窗，系统日志记录用户允许并创建 `com.yangbukun.lives` 的 PhotosAdd 授权记录。此次弹窗验证发生于版本号仍为 0.1.7 的修复测试包，未重置用户权限重复弹框。
- 安装提示背景、Applications 链接、640 × 440 窗口和图标位置已通过只读挂载后的 Finder `.DS_Store` 检查。
- 未重新执行干净用户的完整安装流程、macOS 13/14 兼容矩阵、全部模板、真实图库写入、iCloud 与 iPhone 回归；不把自动化或签名验证等同于这些验收。

## 冻结安装包

- 最终 DMG：`Lives_0.1.8_aarch64.dmg`
- SHA-256：`f01ddfeb3797fb262165a080472e5fbe4c6ba36852caf56bb5cf737e6ff9bc37`
- Apple 公证：App `c038e188-aa93-4fc7-a885-7163a53cb3bd`，DMG `df551538-b979-43b1-b63c-89d6b09f6066`，均为 `Accepted`，并已钉入票据。
- 构建脚本中的 PASS 7 已通过 `spctl`，结果为 `accepted / source=Notarized Developer ID`。
- 本次构建阶段签名、公证和 Gatekeeper 验证均通过，发布资产以本次 Apple 公证结果和构建阶段 PASS 3/7 为准。
- 隔离导出冒烟测试在当前 macOS 环境因 AVFoundation 缺少音频编码器返回 `Cannot Encode`，未写入图库；不据此宣称完整导出链路通过。
