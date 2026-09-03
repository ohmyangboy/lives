# 文件夹素材库同步功能实施计划

## 目标
导入过的文件夹项目支持同步：新视频自动加入、已消失的视频自动移除（完整镜像语义，扫描失败时绝不删除）。触发方式 = 手动刷新按钮 + 轻量自动（启动后、切到文件夹项目时静默重扫）。不做同名文件替换检测（无 mtime/size），不改 Swift/Rust。

## 核心设计

### 1. 同步算法（提取为纯函数，便于测试）
在 `src/domain.ts` 新增 `planFolderSync(scanPaths, clips, project, allProjects)`：
- `toAdd`：scanPaths 中有、但全局 clips（按 sourcePath 去重，App.tsx:407 同款逻辑）中没有的路径
- `toRemoveFromProject`：project.clipIds 中 sourcePath 不在 scanPaths 里的 clip
- `toRemoveGlobally`：其中 sourcePath 不被**其他任何项目**引用的 clip（处理"文件在两个文件夹项目间移动"的情况：只从本项目摘除，不全局删除）
- 复用 `removeClip`（App.tsx:722）的级联语义：移除 clip 时同步清理所有项目的 clipIds 和 slotPlacements（按 sourceClipId 过滤）

### 2. `importPaths` 小重构（App.tsx:406）
- 返回值从 void 改为 `{ added, failed, projectClipIds }`，供同步后组装提示文案
- 加 options 参数 `{ activate?: boolean }`（默认 true）：自动同步后台刷新非当前项目时不抢焦点、不改 selectedMaterialId；现有调用方行为不变

### 3. 同步执行函数（App.tsx）
`syncFolderProjects(projects, { silent })`：
- 前置检查：desktopAvailable、未在导入中（importProgress 为空）、`syncingRef` 防重入
- 每个项目：`setImportProgress({done:0,total:1})` 占位 → `nativeService.scanFolder(folderPath)`
  - **扫描抛错（含 SOURCE_FOLDER_UNAVAILABLE，外置盘未挂载场景）→ 跳过该项目，绝不删除**；silent 模式不弹提示，手动模式 setNotice 告知
  - 先执行删除（setClips/setMediaProjects/setSlotPlacements，含 selectedMaterialId 指向被删 clip 时的清理）
  - toAdd 非空才走 `importPaths(toAdd, project, { activate: silent ? false : ... })`（空列表不能调，避开 App.tsx:409 的"请选择视频"误导提示）
- 完成后组装 notice：手动刷新总是反馈（`已是最新` / `新增 X 段，移除 Y 段` + 失败原因）；自动同步仅在确有增删时轻提示，静默失败

### 4. UI 挂载点
- **刷新按钮**：`.panel-title-row`（App.tsx:926）帮助按钮左侧，仅当前项目为 folder 时显示；`src/icons.tsx` 新增 RefreshIcon；同步中旋转态；样式复用 `context-help-button`
- **空状态按钮**（App.tsx:950）：folder 项目空列表时，"重新导入文件夹，或切换其他项目。"文案下加「重新扫描文件夹」按钮——直接解决截图中 "paperrss 0" 的困境
- **修复空项目关不掉**：`.media-project-close`（App.tsx:936）目前仅 clipIds.length > 0 时渲染，改为始终渲染（closeMediaProject 已能正确处理空项目）

### 5. 自动同步触发（轻量，无 watcher）
- **启动后**：媒体库恢复完成且 desktop bridge 可用后，对所有 folder 项目静默同步一次（fire-and-forget，不阻塞首屏）
- **切换项目时**：activeProjectId 变为 folder 项目时静默同步该项目；距上次同步 <3 秒则跳过（避免与启动同步重复触发）

### 6. 测试
`src/domain.test.ts` 新增 `planFolderSync` 用例：新增/删除/跨项目移动文件/空扫描结果/重复路径等。

## 改动文件
- `src/domain.ts`：新增 planFolderSync 纯函数
- `src/domain.test.ts`：新增测试
- `src/App.tsx`：importPaths 重构、syncFolderProjects、刷新按钮、空状态按钮、关闭按钮修复、两个自动同步 effect
- `src/icons.tsx`：RefreshIcon
- `src/styles.css`：刷新按钮/空状态按钮/旋转态样式

## 明确不做
- 不做 mtime/size 修改检测（clip 结构与 localStorage schema 不动）
- 不做 FSEvents watcher（sidecar 协议不动）
- 直连导入项目（direct）不参与同步

## 成本结论
纯前端改动约 200~300 行（含测试），无原生改动、无新依赖、无 schema 迁移。scanFolder 毫秒级、inspect 仅对新文件触发（header 解析），同步本身开销可忽略；主要风险点（未挂载盘误清空）已用"扫描失败绝不删除"闸门规避。