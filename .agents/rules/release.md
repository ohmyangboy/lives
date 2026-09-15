# Lives Mac 发布规则

> 2026-09-15：本仓库同时承载 Mac 源码与官网源码，对外远端即 `SOURCE_URL`。发布入口已按单仓库模型校验；官网由 `.github/workflows/pages.yml` 从 `website/` 源码构建部署，不在发布工具内推送生成产物。

## 触发与参考

准备 Release、调整版本/tag、修改发布脚本、上传或部署前读取本文；签名、公证与 DMG 细节见 [Mac 发布规则](mac-release.md)，涉及工作流或服务器部署另读 [Actions 规则](github-actions.md)。日常 Debug 无需加载。

实际命令、版本更新位置、发布附件白名单与公开通道步骤见 [发布流程](../../docs/release-workflow.md)。本文维护约束，操作文档维护实现步骤；发现命令或状态不一致时核对现有脚本与远端，更新对应文档，不绕过门禁。

以下命令和路径相对本仓库根目录。

## 源码与授权边界

Mac 源码按已批准的边界维护，公开仓库只接收审查过的内容。保留公开历史、tag、Release 与同名资产；后续修复使用新版本或新 build。提交、推送、上传、部署及上架按本轮授权范围执行，已有授权无需重复请求。

应用、内部 Core、配置与测试一起审查和提交。依赖升级同步锁文件和许可记录；内部 Core 由本仓库提交固定，不需要独立 Core tag。

## 正式构建来源

`python3 scripts/core_dependency.py --release` 检查发布来源、本仓库 Core 路径真实存在、Core 不属于嵌套仓库及仓库处于干净提交。正式包记录仓库 commit、`packages/LivesCore` 的 tree hash、工具链、版本/build 与产物 SHA-256。

私有 tag 使用 `mac/v<版本>`，公开 Mac Release 仍用 `v<版本>`。不要移动已发布的 tag。

## 发布说明与完成标准

按目标渠道完成测试、构建、产物、Changelog、相关 README/官网、Tag/Release 和线上验证。发布说明采用“一句话概要 + 更新要点”，整块中文在上、`---` 分隔、整块英文在下。

来源门禁、签名、安装启动、真实交互和远端发布分别记录；证据绑定当版提交与产物，失败或待处理项目保持未完成。平台特有的约束与完成证据见 [Mac 发布规则](mac-release.md)。
