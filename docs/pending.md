# 待办与待验事项

本仓库由拆分而来，上一代单仓库的提交历史保存在工作区的迁移备份中。以下事项**尚未完成**；
下次开发时逐项校验。本文件存在不代表这些项目已通过。

## 发布门槛（对外发布前必须完成）

- [ ] **权属范围**：核对自有代码、外部贡献与历史迁移代码的权利覆盖，保留可核验记录。
      `LICENSING.md` 已记录该项待办。
- [ ] **品牌资源**：`packages/LivesCore/Sources/LivesCore/Resources/WatermarkAppIcon.png`
      的对外可分发性需单独确认；不能以删除资源代替运行时验证。
- [ ] **官网版本**：`website/package.json` 当前保持 `0.1.14`（已发布版本），避免线上出现
      未发布版本号；发布 `0.1.15` 时随发布提交升到 `0.1.15`，届时
      `scripts/release_preflight.py` 的版本一致性检查才会通过。

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
