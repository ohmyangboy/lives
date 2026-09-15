# Lives Mac Actions 约束

## 何时阅读

新增、修改或排查工作流、CI 凭据、缓存、artifact、Pages 或服务器部署时先阅读本文。实际发布或部署还须阅读 [发布规则](release.md) 与 [Mac 发布规则](mac-release.md)。

以下路径相对本仓库根目录。目录状态是编写时的本地快照，执行前重新核对，不据此推断线上已部署。

## 工作流入口

本站点的 Pages 与服务器部署工作流位于本仓库 `.github/workflows/`，站点源码在 `website/`。`website/.github/workflows/` 不在仓库根目录，不会作为本仓库的 Actions 自动运行。改动时先核对分支、触发路径与 `.github/workflows/` 根位置，不要据此声称线上流程已启用。[GitHub 工作流规则](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflows)

## 权限与执行隔离

新增或修改工作流时：`GITHUB_TOKEN` 默认只读，写权限限于所需 job；引用的 Action 固定到核验过的完整 commit SHA。PR 检查与持有部署凭据的任务隔离，特权触发器不得执行不可信 PR 代码；事件文本通过环境变量传入并引用，避免直接拼接 Shell。按目标环境限制部署分支、设置超时与并发组，避免打断正在发布的任务。[GitHub 安全建议](https://docs.github.com/en/actions/reference/security/secure-use)

## 凭据、产物与完成标准

沿用本机签名、公证和上传流程，未获授权不将 Apple 私钥搬入 CI。服务器使用已核验的 known_hosts 和严格主机校验；缓存不得包含凭据或替代正式构建来源，公开 artifact/日志不得带私有源码与用户素材。变更报告明确区分本地检查、远端 Actions 成功和最终站点/下载验收。
