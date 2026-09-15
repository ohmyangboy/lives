# Lives Mac 协作约定

本文件的路径与命令相对本仓库根目录。
默认使用中文沟通，在用户意图和已有授权范围内自主推进，优先最小、完整、可验证的改动。

## 产品与核心代码边界

本仓库独立维护。`packages/LivesCore` 是本仓库内部模块，不是跨仓库共享库，不独立发版。

- 只引用本仓库内的核心代码，不依赖相邻仓库或旧共享目录。
- 修改内部 Core 时，适配本仓库调用方并验证相关行为。
- 不默认要求与另一产品保持接口、功能或版本一致。
- 未经明确要求，不同步另一产品，也不重新提取共享库。
- 跨产品移植前核对来源、许可、适配需求和测试范围。
- 保持本仓库旧数据兼容，不因相邻仓库变化自动迁移数据。

## 工作边界

- 修改前检查仓库状态；已有修改默认属于用户或其他 Agent，不覆盖、回滚或顺手清理无关内容。
- 凭据、私有材料与用户数据不进入公开仓库、日志或公开附件。
- 不使用真实草稿、系统图库或用户数据做破坏性测试。
- 产品行为、隐私、权限、新平台或超出任务范围的依赖变化需要明确授权。
- 依赖变化同步锁文件与许可记录；沿用相邻代码的结构、命名、格式和本地化方式，避免无关重构与批量格式化。
- 共享构建目录不得并发污染；清理限于本任务拥有、可重建的输出，保留必要证据。

## 模块与代码

- `src/`：React / TypeScript 界面；`src-tauri/`：Rust 宿主；`native/LivePhotoService/`：Swift Helper，通过 `../../packages/LivesCore` 引用本仓库引擎。
- `packages/LivesCore/`：本仓库内部的模型、媒体处理与渲染；资源与测试分别位于 `Sources/LivesCore/Resources/`、`Tests/LivesCoreTests/`。
- `website/src/`：官网源码；`docs/`：开发与发布参考；`.agents/rules/`：发布、Actions 与协作规则。
- TypeScript 使用 2 空格、单引号和省略行末分号；Swift / Rust 使用 4 空格，沿用相邻文件风格。组件和类型使用 `UpperCamelCase`，Swift / TypeScript 成员使用 `lowerCamelCase`，Rust 函数使用 `snake_case`。
- 权限、平台 UI 与系统图库交互留在平台层；Helper 与宿主之间的 JSON 协议变化要核对调用、响应、错误与取消行为。

## 验证

按影响范围选择验证，不默认运行整套检查。命令在本仓库根目录执行：

```sh
npm test                                              # 前端 Vitest
npm run build                                         # 前端生产构建
swift test --package-path packages/LivesCore           # 内部 Core
swift test --package-path native/LivePhotoService      # Swift Helper
python3 -m unittest discover -s scripts -p 'test_*.py' # 产品工具
npm run website:build                                 # 官网
```

- 仅前端构建不能证明 Rust 宿主、Helper、应用交互或签名包通过；原生变化补充对应构建与真实交互。
- 超时、零测试、跳过关键步骤或不完整结果不算通过；无法执行的验证说明原因与剩余风险。
- 安装成功、应用启动、交互验收和发布就绪是不同结论，不互相替代。

## 按需读取

- 代码约定与常用命令：[开发参考](docs/development.md)。
- 版本、签名、公证、DMG、官网与公开通道：[发布流程](docs/release-workflow.md) 与 [Mac 发布规则](.agents/rules/mac-release.md)；日常 Debug 不触发发行规则。
- 发布前置检查与共享约束：[发布规则](.agents/rules/release.md)。
- 工作流、CI 权限、凭据、缓存、artifact 或部署：[Actions 规则](.agents/rules/github-actions.md)。
- 未完成的发布门槛与待验事项：[待办与待验](docs/pending.md)。

## 交付

说明实际修改、验证命令与结果、证据位置及待验事项。提交和 PR 聚焦本次工作，沿用 `feat:`、`fix:`、`refactor:`、`chore:`、`docs:` 等前缀。
