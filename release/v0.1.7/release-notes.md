# Lives 0.1.7

适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高的正式版本。

本版本与 0.1.6 功能一致，是从 0.1.6 起首个**由全新更新链路交付**的版本：从 0.1.6 升级到本版本的过程，即为新的「静默下载 → 一键重启 → 原子换包 → 复活新版」完整链路的真机验证。

## 更新要点

- **自动更新全链路真机验证版本**：
  - 0.1.6 用户将实际体验新更新链路：冷启动静默检查 → 后台自动下载（SHA-256 校验）→ 胶囊一键「重启」原子换包并进入 0.1.7；
  - 若更新过程异常退出，下次冷启动会直接提示完成安装，不重复下载。
- **官网同步更新**：
  - 官网版本信息与自动更新说明同步至 0.1.7；
  - 恢复官网 Pages 自动部署流水线（推送 main 即自动更新官网）。

## 说明

- 若重启过程出现异常，请查看 `~/Library/Caches/com.yangbukun.lives/Updates/relaunch.log` 并附上日志反馈。

## 文件校验

`Lives_0.1.7_aarch64.dmg`

`252682358cf2ddf6d1640beeed9a28c3ba36e5a6c80faf0886e69ff77d07f555`

---

# Lives 0.1.7

For Apple Silicon Mac, requires macOS 13 Ventura or higher.

Feature-identical to 0.1.6, and the first release delivered entirely through the new update chain: upgrading from 0.1.6 exercises the full "silent download → one-click restart → atomic swap → relaunch" flow on real hardware.

## Key Updates

- **End-to-end verification of the new auto-update chain**:
  - 0.1.6 users will experience the reworked chain first-hand: silent check on cold start, background download with SHA-256 verification, one-click restart with atomic swap into 0.1.7;
  - Interrupted updates resume on next launch without re-downloading.
- **Website sync**:
  - Website version info and auto-update FAQ updated to 0.1.7;
  - Restored the GitHub Pages auto-deploy pipeline (pushes to main now update the website automatically).

## Notes

- If a restart goes wrong, check `~/Library/Caches/com.yangbukun.lives/Updates/relaunch.log` and attach it when filing feedback.

## Checksums

`Lives_0.1.7_aarch64.dmg`

`252682358cf2ddf6d1640beeed9a28c3ba36e5a6c80faf0886e69ff77d07f555`
