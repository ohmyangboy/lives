# Mac 发布与签名规则

## 触发与参考

Mac Release、签名、公证、DMG、发行配置或发布脚本变更前读取本文及 [发布规则](release.md)。官网部署或公开通道切换另读 [Actions 规则](github-actions.md)。

实际命令、版本更新位置、发布附件白名单、官网与通道切换步骤见 [发布流程](../../docs/release-workflow.md)。路径与命令相对本仓库根目录。

## 签名与公证

本机 Developer ID 签名覆盖 App、Helper 与嵌入代码，核验 Hardened Runtime、时间戳、entitlements。最终包完成 `codesign` 校验、`notarytool` 公证、`stapler` 附票验证和 Gatekeeper 检查；失败时修复原因，不以 ad hoc 签名、跳过公证或关闭系统保护代替。[Apple 公证要求](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

沿用 `scripts/notarize-and-package.sh` 与发布入口，不另建绕过来源校验的打包路径。保留签名、公证与最终产物校验记录，明确对应仓库提交、版本和文件哈希。

## 渠道与产物

沿用本机签名、公证和 `npm run release:prepare` → `release:publish` → `release:verify` 流程。`prepare --build` 会向 Apple 提交公证，不能当作完全离线操作；公开上传和部署按任务授权范围执行。

公开附件遵守现有白名单，审核冻结 payload 后发布，核验服务器下载与元数据。官网由 `.github/workflows/pages.yml` 从 `website/` 源码部署，不由本工具推送；稳定官网不提前指向未发布包，重试复用已核验产物，不重新打包覆盖同名附件。规则存在不代表首次公开发布已完成，操作前核对当前远端。

## 完成标准

核对真实下载、版本、大小、SHA-256、站点及对应 Actions 结果。保留签名与公证记录、最终产物哈希和回退所需的历史版本；安装启动与 Photos/HDR 等交互验收分别报告。
