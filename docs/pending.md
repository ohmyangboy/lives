# 待办与待验事项

本仓库由拆分而来，上一代单仓库的提交历史保存在工作区的迁移备份中。以下区分已完成的发布验证与仍需设备验收的事项；自动测试和公证不替代真实交互验收。

## 0.1.16 发布（已完成）

- [x] 当前工作区全部修改与品牌资源来源核对：[来源记录](releases/0.1.16-source-check.md)。
- [x] 应用、原生宿主、Helper 与官网版本统一为 `0.1.16`。
- [x] `mac/v0.1.16` 与公开 `v0.1.16` 指向干净的正式构建提交。
- [x] 首次从本仓库完成 Swift Helper 与 Rust 宿主正式打包。
- [x] 完整跑通 `release:prepare` → `release:publish` → `release:verify`，验证签名、公证、四个附件、自有源元数据、真实下载和两份官网。
- [x] 服务器 Secret、部署开关和严格主机校验通过实际 Actions 验证。
- [x] 官网 build、Pages deploy 与 server deploy 全部成功。
- [x] 最终 DMG 挂载、复制 App、签名/Gatekeeper 核验与本机后台启动检查通过。

完整提交、Core tree、产物 SHA-256、公证编号及 Actions 链接见 [发布验证记录](releases/0.1.16-verification.md)。0.1.15 草稿未正式发布，已由包含全部工作区修改的 0.1.16 取代；公开 tag 保留。

## 待验（设备与交互）

- [ ] Photos 授权与保存、HDR 输出、iCloud/iPhone 同步，以及旧版应用内更新的完整安装重启闭环。
- [ ] macOS 13/14 等其他系统版本的安装启动与真实交互。
- [ ] 缺少外部素材而跳过的 Core 7 项、Helper 4 项回归，在对应素材可用时补验。
