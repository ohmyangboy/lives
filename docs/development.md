# Mac 开发参考

本文保存本仓库的事实与常用命令，按需查阅，不是每次任务的必做清单。协作边界以 [AGENTS.md](../AGENTS.md) 与 [.agents/rules/](../.agents/rules/) 为准。

## 模块

- `src/`：React / TypeScript 界面；`src-tauri/`：Rust 宿主；`native/LivePhotoService/`：Swift Helper。
- `packages/LivesCore/`：本仓库内部的模型、媒体处理与渲染；可使用 AVFoundation / CoreImage，UI、权限及图库交互留在平台层。资源与测试分别位于 `Sources/LivesCore/Resources/`、`Tests/LivesCoreTests/`。
- `website/src/`：官网源码；`scripts/`：开发、构建与发布工具；`docs/`：本参考与 [发布流程](release-workflow.md)。

内部 Core 是本仓库自有副本；修改时适配本仓库调用方即可，不要求与相邻仓库保持一致。

## 常用命令

以下命令在本仓库根目录执行，只选择与本次改动相关的项。本机按需准备 Xcode、Node.js、Rust 或 Python 3。

```sh
npm ci
npm run dev:mac                                  # 前端热更新 + 开发 Helper
npm run dev:mac:app                              # 构建签名 Debug .app 并启动
npm run build                                    # 前端生产构建
npm test                                         # 前端 Vitest
swift test --package-path packages/LivesCore      # 内部 Core
swift test --package-path native/LivePhotoService # Swift Helper
npm run build:sidecar                            # Sidecar / Helper / Core 资源包
npm run website:build                            # 官网静态构建
npm run website:preview                          # 官网本地预览（-- --shots 断点边界截图与越界查看）
python3 -m unittest discover -s scripts -p 'test_*.py'
```

Shell 修改先检查 `bash -n <脚本>` 并补充针对性行为验证；Python 做语法与针对性测试。前端构建不代表 Rust 宿主、Helper、应用交互或签名包通过。当前没有统一覆盖率门槛；测试素材缺失时说明跳过的范围与原因。

## 代码与资源

沿用相邻文件风格，避免无关格式化。优先复用现有模块，新增抽象和依赖应有具体需求。共享资源变化核查调用方、旧草稿、字体许可、OFL 文本和水印等资源打包；依赖变化同步锁文件与许可记录。

Mac 复用现有 Cargo `target` 与 Swift `.build`；缓存保留可加快增量构建，不在每次运行前 clean。清理限于本任务拥有、可重建的输出，保留必要证据。

## 照片保存反馈诊断

照片授权和保存会将结构化诊断保存在 `~/Library/Logs/Lives/photo-diagnostics.json`，最多 64 条、64 KiB，每次写入清理 7 天前的记录。只记录时间、进程号、操作结果、添加/读写授权状态、生成文件是否存在及可读和字节数、允许列表中的系统错误 domain/code（含最多 4 个底层错误）。不记录素材内容、文件名、路径、照片 identifier、错误描述或完整 `userInfo`。

点击邮件或 GitHub Issue 反馈时，草稿正文会附带最近 7 天内最多 6 条诊断的有界摘要，用户可在发送前查看或删除；应用不会自动发送。原始 `photo-reset.log` 不会附带。旧版已经丢弃的系统错误无法补录，需要用户在包含此改动的版本再次触发故障。诊断记录失败不影响原保存结果。

反馈面板的“复制日志”会将同一份设备信息与照片保存诊断复制到剪贴板，便于粘贴到其他联系渠道；成功时显示“已复制”，失败时可重试。
