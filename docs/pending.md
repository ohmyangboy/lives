# 待办与待验事项

本仓库由拆分而来，上一代单仓库的提交历史保存在工作区的迁移备份中。以下事项**尚未完成**；
下次开发时逐项校验。本文件存在不代表这些项目已通过。

## 0.1.16 发布准备

- [x] 本次源码与品牌资源来源核对：[记录](releases/0.1.16-source-check.md)。
- [x] 应用、原生宿主、Helper 与官网源码版本统一为 `0.1.16`；官网待 Release 可下载后部署。
- [x] 服务器 known_hosts Secret 已依据本机既有记录配置，工作流启用严格主机校验。

## 首次发布（本仓库尚未发过版）

- [ ] `mac/v<版本>` tag 指向待发布的干净提交；发布预检当前停在这一项。
- [ ] 端到端跑一次 `npm run release:prepare` → `release:publish` → `release:verify`，
      验证签名、公证、附件白名单、服务器下载与线上站点验收链条。
- [ ] 服务器同步前置条件：`LIVES_RELEASE_SYNC_ENABLED`、`LIVES_SERVER_DEPLOY_ENABLED`
      与 `LIVES_SERVER_KNOWN_HOSTS`；`scripts/release.py` 的 `public_guard()` 会在发布前校验。
- [ ] 官网部署：推送到 `main` 且涉及 `website/**` 时由 `.github/workflows/pages.yml`
      构建部署，部署前会跑 `scripts/check_website.py`。

## 待验（设备与交互）

- [ ] 安装启动与真实交互：签名 `.app` 的安装、Photos 授权与保存、HDR 输出、应用内更新。
- [ ] 拆分后首次从本仓库完成一次原生构建与 Rust 宿主打包。
