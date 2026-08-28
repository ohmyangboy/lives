import XCTest
@testable import LivePhotoService

final class UpdateServiceTests: XCTestCase {
    // MARK: - relaunch 脚本安全属性

    func testRelaunchScriptContainsAtomicSwapAndFallbacks() {
        let script = UpdateService.relaunchScript()

        // 原子换包：必须先备份旧包（mv 到 .old），绝不直接 rm -rf 目标
        XCTAssertTrue(script.contains(#"mv "$TARGET_APP" "$OLD_BUNDLE""#), "必须先把旧包改名让位（原子 rename）")
        // rm 目标仅允许出现在 ~/Applications 兜底分支（此时目标已切到用户目录，且非运行中的主安装）
        let fallbackMarker = script.range(of: #"TARGET_APP="$USER_TARGET""#)
        if let rmRange = script.range(of: #"rm -rf "$TARGET_APP""#) {
            XCTAssertNotNil(fallbackMarker, "rm 目标包只能出现在兜底分支")
            XCTAssertGreaterThan(rmRange.lowerBound, fallbackMarker!.lowerBound, "rm 目标包必须发生在切换到兜底目录之后")
        }
        XCTAssertTrue(script.contains("swap_same_volume"), "同卷 rename 优先")
        XCTAssertTrue(script.contains("ditto"), "跨卷必须有 ditto 拷贝路径")
        XCTAssertTrue(script.contains(#"mv "$OLD_BUNDLE" "$TARGET_APP""#), "换包失败必须回滚旧包")

        // 兜底目录
        XCTAssertTrue(script.contains(#"$HOME/Applications/Lives.app"#), "主目标不可写时兜底用户目录")

        // 复活验证 + 降级链
        XCTAssertTrue(script.contains(#"open -n "$TARGET_APP""#), "首选 open -n")
        XCTAssertTrue(script.contains(#"pgrep -f "$TARGET_APP/Contents/MacOS""#), "必须用 pgrep 验证新进程存在")
        XCTAssertTrue(script.contains("launching executable directly"), "open 失败后必须直接拉起二进制")
        XCTAssertTrue(script.contains(#"nohup "$TARGET_APP/Contents/MacOS/$EXEC_BIN""#), "直接拉起需脱离会话")

        // 温和终止升级链：宽限 -> TERM -> KILL
        XCTAssertTrue(script.contains("sending SIGTERM"))
        XCTAssertTrue(script.contains("sending SIGKILL"))

        // 全程日志，禁止静默吞错：关键命令输出重定向进日志
        XCTAssertTrue(script.contains(#"2>>"$LOG""#))
        XCTAssertTrue(script.contains("FAILED:"))
        XCTAssertTrue(script.contains("SUCCESS: relaunched"))

        // staging 与清单的清理必须位于「复活验证通过」分支内（失败时保留现场供恢复）
        let successBranchMarker = script.range(of: #"if [ "$RELAUNCHED" -eq 1 ]; then"#)
        let stagedCleanupIndex = script.range(of: #"rm -rf "$UPDATES_DIR/staged""#)
        let successIndex = script.range(of: "SUCCESS: relaunched")
        XCTAssertNotNil(successBranchMarker)
        XCTAssertNotNil(stagedCleanupIndex)
        XCTAssertNotNil(successIndex)
        XCTAssertLessThan(successBranchMarker!.lowerBound, stagedCleanupIndex!.lowerBound)
        XCTAssertLessThan(stagedCleanupIndex!.lowerBound, successIndex!.lowerBound)
    }

    // MARK: - 版本比较

    func testIsVersionComparesSemantically() {
        XCTAssertTrue(UpdateService.isVersion("0.1.8", newerThan: "0.1.7") == true)
        XCTAssertTrue(UpdateService.isVersion("v0.2.0", newerThan: "0.1.9") == true)
        XCTAssertTrue(UpdateService.isVersion("0.1.7", newerThan: "0.1.7") == false)
        XCTAssertTrue(UpdateService.isVersion("0.1.6", newerThan: "0.1.7") == false)
        XCTAssertTrue(UpdateService.isVersion("0.1.10", newerThan: "0.1.9") == true)
        XCTAssertTrue(UpdateService.isVersion("0.2", newerThan: "0.1.9") == true)
        XCTAssertNil(UpdateService.isVersion("beta", newerThan: "0.1.7"), "无法解析的版本必须返回 nil")
    }
}
