# Lives 0.1.6

适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高的正式版本。推荐所有用户升级。

本版本对应用内自动更新的「下载完成 → 点击重启 → 替换安装 → 复活新版」全链路做了重构，彻底修复点击“重启”后偶发的无响应/卡住问题。

## 更新要点

- **重启安装链路重构（核心修复）**：
  - 弃用“先删除再拷贝”的旧替换方式，改用同卷 rename **原子换包**：瞬时完成、失败自动回滚旧版本，不再出现旧版已退出、新版未就位的空窗；
  - 新增**复活验证链**：替换完成后启动新版本并确认进程真实运行，失败自动逐级降级（`open` 重试 → 直接拉起新版主程序），任何一步都有兜底；
  - 主进程退出改为**温和终止升级**（等待 10 秒 → SIGTERM → SIGKILL），避免慢关机窗口内被硬杀；
  - 替换脚本以脱离进程树的孤儿进程运行，全程日志写入 `~/Library/Caches/com.yangbukun.lives/Updates/relaunch.log`，问题可追溯。
- **更新状态看门狗（任何状态必然收尾）**：
  - 检查更新 12 秒超时、下载停滞 90 秒自动取消并给出可重试的失败提示，不再出现永久转圈；
  - 点击重启后若进程未能正常退出，自动重试退出并强制关闭窗口，后台仍会完成替换与复活。
- **更新中断自动恢复**：
  - 下载完成的更新包持久化暂存清单；若更新未完成就退出，下次冷启动直接提示「重启 vX」完成安装，无需重新下载。
- **Apple Developer ID 官方签名与公证**：
  - 完整签署 Developer ID 证书并通过 Apple Notary 官方公证（Notarized & Stapled）。

## 文件校验

`Lives_0.1.6_aarch64.dmg`

`a3032d1025fcddce721b3bb2e082047a8a4b454223191273e9a98c947eb238a6`

---

# Lives 0.1.6

For Apple Silicon Mac, requires macOS 13 Ventura or higher. Recommended for all users.

This release reworks the full in-app auto-update chain ("downloaded → click restart → swap & install → relaunch") and permanently fixes the intermittent stuck/unresponsive restart issue.

## Key Updates

- **Relaunch & Install Chain Rework (core fix)**:
  - Replaced "delete-then-copy" with same-volume **atomic rename swap**: instant, with automatic rollback of the previous version on failure — no more window where the old app has quit but the new one is not in place;
  - Added a **relaunch verification chain**: after swapping, the new version is launched and verified running, with layered fallbacks (`open` retry → direct executable launch);
  - Graceful parent termination escalation (10s wait → SIGTERM → SIGKILL) instead of a hard kill;
  - The installer script runs detached from the app process tree and logs every step to `~/Library/Caches/com.yangbukun.lives/Updates/relaunch.log` for full traceability.
- **Update state watchdogs (every state terminates)**:
  - Check updates times out after 12s; downloads stalled for 90s are auto-cancelled with a retryable failure message — no more endless spinners;
  - If the app fails to exit after clicking restart, exit is retried and the window force-destroyed while the background script still completes the swap and relaunch.
- **Interrupted-update recovery**:
  - A staged-update manifest survives restarts; if an update was downloaded but not installed, the next cold start offers one-click "Restart to vX" without re-downloading.
- **Apple Developer ID Code Signing & Notarization**:
  - Fully signed with Developer ID certificate and notarized & stapled by Apple Notary service.

## Checksums

`Lives_0.1.6_aarch64.dmg`

`a3032d1025fcddce721b3bb2e082047a8a4b454223191273e9a98c947eb238a6`
