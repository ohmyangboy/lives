# Mac 开发与发布流程

本文的命令与路径相对本仓库根目录。迁移状态与来源映射见私有迁移记录。

## 开发和提交

`npm run dev:mac` 启动带前端热更新的开发模式，并通过显式开发路径启动照片 Helper；修改 Swift Helper 后需重启该命令。

验证照片授权、图库保存和完整导出流程时，先退出已有 Lives 窗口，再执行 `npm run dev:mac:app`。该命令构建签名的 Debug `.app`，检查主应用与照片 Helper 的签名权限后启动；不执行发布脚本或生成 DMG。应用使用打包后的前端，修改后需重新执行。首次系统授权需手动允许，构建和签名检查不能替代实际照片保存验收。

Mac Helper 通过 `../../packages/LivesCore` 引用本仓库内部 Core；不存在独立 Core 版本同步步骤。应用、内部 Core、测试与配置一起提交，依赖变化同步 Cargo / npm 锁文件。

## 正式构建来源

`python3 scripts/core_dependency.py --release` 检查发布来源、本仓库 Core 路径真实存在、Core 不属于嵌套仓库及仓库处于干净提交。正式包记录仓库 commit、`packages/LivesCore` 的 tree hash、工具链、版本/build 与产物 SHA-256。仓库内相对依赖由这一个提交固定，不要求 Core 单独打 tag。

发布准备 tag 使用 `mac/v<版本>`，对外 Release 仍用 `v<版本>`。不要移动已发布的 tag。

## 正式版本

需要 Xcode、Rust、Node、Python 3.11+、create-dmg、cargo-about 0.9.2，以及本机钥匙串内 Developer ID 与 Notary profile。发布使用本机 gh 登录，不把签名或服务器密钥转移到 CI。

1. 更新 `package.json`、`package-lock.json`、Cargo 元数据、tauri 配置、Helper Info 和 `website/package.json` 的版本，提交验证过的改动。
2. 给当前提交建立 `mac/v<版本>` tag，准备经过审查的公开说明文件。
3. 执行 `npm run release:prepare -- --notes /absolute/path/notes.md --build`。工具构建、签名、在线公证，校验 Gatekeeper 并生成第三方源码附件；此阶段只向 Apple 提交公证，不发布 GitHub Release。
4. 审查 `.local/publication/payload` 后，运行 `npm run release:publish`。先创建草稿，逐个上传并核验明确白名单中的四个附件，再发布。服务器下载及元数据匹配后才提交官网静态文件。同步尚未完成时，等待工作流成功，再重复相同命令继续，不重新打包或覆盖同名资产。
5. 运行 `npm run release:verify`，保存公开 Release、服务器下载/manifest、两份官网及工作流成功证据。实际交互与 Photos/HDR 验收另行记录。

省略 `--build` 时，必须已有本机签名脚本生成的 `build-receipt.json`，其仓库 commit、Core tree 和四个文件哈希须全部匹配。缓存与正式准备产物在 `.local/` 与 `release/`，不提交到 Git。

公开资产仅限 DMG、其 SHA-256、第三方源码 tar.gz 及其 SHA-256。公开 tag 指向公开分发资料提交；不使用通配符上传整个目录。公证失败不会自动跳过公证。

## 官网源码与更新

源文件位于 `website/`；`website/package.json` 的版本必须与应用一致（`release_preflight` 会校验）。`npm run website:build` 生成 `website/dist`，`npm run website:check` 校验输出没有占位符、本地路径、source map、密钥或未获准公开的格式。

推送到 `main` 且改动涉及 `website/**` 时，`.github/workflows/pages.yml` 自动构建、校验并部署到 GitHub Pages 与服务器。本机不推送生成产物，也不做官网的独立冻结发布；官网更新随普通提交进入 `main`。构建不等于部署成功，部署结果由 `npm run release:verify` 验收。

## 公开通道切换（尚未执行）

本仓库同时承载应用源码与官网源码，对外远端就是本仓库；`.github/workflows/pages.yml` 从 `website/` 源码构建部署，`sync-release-server.yml` 在 Release 发布后同步服务器。

首次公开前的检查：核对远端 `main` 没有未知提交；确认 `LIVES_SERVER_KNOWN_HOSTS` 等服务器 Secret 已按经核验的身份配置；确认 `LIVES_RELEASE_SYNC_ENABLED=true` 与 `LIVES_SERVER_DEPLOY_ENABLED=true`。`scripts/release.py` 的 `public_guard()` 会在发布前校验这些前置条件。

服务器继续执行 `sync-lives-release` 和 `deploy-lives-website`；manifest 协议保持 `currentVersion`、`size`、`sha256` 与固定下载 URL。需要回退时正常 revert 提交，保留历史及 Release。

本机 SSH 身份此前无法直接认证服务器，端到端部署仍待首次发布时验收；不因本地脚本检查通过而认定线上发布已完成。
