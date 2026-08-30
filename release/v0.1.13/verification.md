# Lives 0.1.13 发布验证

日期：2026-08-30。

## 功能与自动化

- 移除独立的更新完成反馈弹窗，复用右上角反馈面板。
- 通过持久化更新重启标记限定首次展示；普通启动不展示，真正显示或手动打开后清除标记。
- 自动展示停留 4 秒、淡出 0.45 秒；用户确认过启动预览效果。浏览器实测淡出中间帧和最终移除，手动打开或接管后超过 4 秒仍保持显示。
- 最终触发条件下，浏览器验证普通启动无反馈弹窗、手动打开正常、标题显示 0.1.13。
- 前端 66 项测试通过（含更新标记读取、清除和存储失败用例），类型检查与生产构建通过。
- Swift 原生全量测试执行 28 项，3 项因外部素材缺失跳过，0 失败。
- 官网构建通过；所有 HTML 占位符已替换，版本、下载链接和更新说明检查通过。

## 签名与公证

- App 版本 `0.1.13`，Bundle ID `com.yangbukun.lives`，架构 `arm64`。
- 完整代码签名、照片权限签名检查及 Gatekeeper 验证通过，身份为 `Developer ID Application: Yonghao Yang (LGKLTGNTY2)`。
- App 公证：`4e8b3976-36ee-4fbf-adce-6bf108e5ffb4`，`Accepted`，票据已封装并验证。
- DMG 公证：`80a8705f-c43f-4243-8b7b-c4d8fe1f7f1f`，`Accepted`，票据已封装并验证。
- 文件：`Lives_0.1.13_aarch64.dmg`，大小 `11221198` 字节。
- SHA-256：`4f7cf6385a8f3fbcad23a94a49855d3f66c16ac9e684988ffe9fd8bfe7bd1193`。

## 人工验收边界

完整的 0.1.12 → 0.1.13 真机安装重启、当前 VPN 与用户自行关闭 VPN 后的网络表现、macOS 13/14、所有导出模板及 iCloud/iPhone 回归仍待验收。自动化与构建成功不代表这些场景已经完成。

## 发布后验证

- 实现提交：`ce5e0637eebe247a14397cabad99c630746a94f3`，正式标签 `v0.1.13`。
- [GitHub Release](https://github.com/ohmyangboy/lives/releases/tag/v0.1.13) 为正式版，DMG 资产摘要与本地一致。
- [下载同步 workflow](https://github.com/ohmyangboy/lives/actions/runs/33315654296) 成功。
- [官网部署 workflow](https://github.com/ohmyangboy/lives/actions/runs/33315657562) 的 Pages 与自有服务器部署均成功。
- `https://lives.1leaf.cc/` 和 `https://ohmyangboy.github.io/lives/` 的首页版本均为 0.1.13，更新日志均包含 4 秒淡出及普通启动不提示的说明。
- GitHub README 已核验为 0.1.13 与新反馈说明。
- 从自有源完整下载 `Lives-latest.dmg`，HTTP 200，`11221198` 字节，SHA-256 与本地及 GitHub 一致。当前网络一次下载耗时 22.66 秒；未切换或确认 VPN 路由，不据此推断大陆各地速度。
- 自有更新清单已刷新为 `v0.1.13`，`updatedAt=2026-08-30T14:02:45Z`，大小与 SHA-256 均匹配正式 DMG；核验使用不带查询参数的正式接口。
