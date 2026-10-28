# Live 文件/照片库导入与原始比例验收（2026-10-27）

实现范围：Lives Mac；分支 `codex/live-import-native-aspect`，worktree `/Users/yangbukun/.codex/worktrees/97b3/lives`。未提交、未合并、未推送；未修改主工作树。

## 行为

- “添加素材”可一次混选 MOV/MP4/M4V 视频和 HEIC/HEIF/JPG/JPEG 照片；照片与 MOV 按 ContentIdentifier 配对（可多组），复用 LivesCore 的照片标识、视频标识和 still-image-time 校验，不以同名作为配对依据。未匹配的照片会报错，本次选择不导入。
- 保留原始照片路径、MOV 路径、尺寸、配对标识和 Live 类型，持久化到现有素材库，并传入拼贴和渲染协议。已导入过的普通 MOV 可以升级为 Live 素材；现有画格保留裁剪、选段及身份。
- 文件配对导入只引用原始资源，不修改；照片移走后导出明确失败。编辑预览与输出封面仍沿用现有时间线选帧行为，没有新增原图封面切换功能。
- 新增“从照片添加”，与“添加素材”（文件导入）并存。仅点击照片库入口时由独立 Photos Helper 请求 `.readWrite` 读取授权，随后显示 `PHPickerViewController`，只筛选 Live Photo、每次最多 10 项。现有保存流程仍使用 `.addOnly`，导入不会重置 TCC 权限，也不修改图库。
- 拒绝、系统限制与未完成授权有独立错误提示及“打开隐私设置”。有限授权可继续选择已授权照片，选择器标题提示访问范围；选中但不可读取的资源明确报错，不降级为普通视频。
- 按 PhotoKit 资源类型提取原始 `.photo` 与 `.pairedVideo`（不混用编辑后的 full-size 资源），允许从 iCloud 下载。复制到 `~/Library/Application Support/Lives/ImportedLivePhotos/<批次 UUID>/`，经 `LivePhotoImporter.pair` / LivesCore 校验后复用现有素材导入流程。成功资源持续保留，取消或 Worker 返回失败会删除本批次临时资源，不影响此前素材。
- Helper 与主 App 均补充 `NSPhotoLibraryUsageDescription`；本地官网权限与隐私文案同步说明读取、下载及本机副本，未部署官网。
- 自定义比例取当前选中画格/素材的旋转后视频尺寸；切换选中素材时重新取原始比例。行内“重置”恢复同一目标。保持现有编码范围 1:3–3:1，超出范围会限制到边界；无选中素材时默认 1:1、重置禁用。
- Live 素材支持至少 1 秒的运动资源，普通视频仍至少 2.5 秒。

## 自动验证

- `npm test`：9 个文件、106 项通过。
- `npm run build`：通过；保留现有大于 500 kB 的 chunk 提示。
- `swift test --package-path native/LivePhotoService --scratch-path /tmp/lives-live-import-helper-build`：原有 36 项中 32 项通过、4 项缺少外部 fixture 跳过。
- 照片库入口最终修改后执行 `swift test --package-path native/LivePhotoService --scratch-path /tmp/lives-live-import-helper-build --filter 'PhotoLibraryImportTests|PhotoAuthorizationTests|LivePhotoImportTests|DurationRenderingTests'`：15 项通过，无跳过。包括读取与写入授权错误区分、有限授权、编辑后 Live 的原始资源选择、取消/失败时清理、成功资源持久保留，以及此前的合成 Live 配对与再次渲染链路。
- `plutil -lint src-tauri/Info.plist native/LivePhotoService/Sources/LivePhotoService/Helper-Info.plist`：通过。
- `git diff --check`：通过。
- 照片库入口验证日志：`/tmp/lives-photos-library-frontend-tests.log`、`/tmp/lives-photos-library-build.log`、`/tmp/lives-photos-library-swift-tests.log`。

未改 Rust 宿主或 LivesCore。Swift 已编译，但没有构建新的签名 App，也未调用真实图库进行授权、选择、下载或写入。权限测试验证状态映射，不证明实际 TCC 弹框；资源测试验证选择和持久化规则，不证明 iCloud 服务行为。真实原生界面、受限授权、HEIC 与 iCloud 下载仍需以下手动验收。

## 手动步骤

使用本 worktree 构建的 Helper 与前端，避免旧安装包加载旧 Helper。仅使用测试素材，不修改真实图库。

1. 在“照片”中把一个测试 Live Photo 导出为未修改原片，获得照片和 MOV；点“添加素材”同时选中两者。应出现一条带 LIVE 标签的素材。
2. 把照片副本改成不同文件名，再导入，应正常配对。分别尝试只选照片、只选 MOV、混用不同 Live 的照片和 MOV、选择同一标识的两份资源，应显示明确错误，不新增普通视频替代品。取消文件选择不新增素材。
3. 对测试文件撤销读取权限后尝试导入，应显示读取错误。此路径不应弹 Photos 授权；“保存到照片”仍使用原有权限流程，拒绝后应显示现有权限提示，真实系统弹窗尚未验收。
4. 将 Live 拖入单画面、二拼和三拼，调整选段、裁剪、声音并导出到测试文件夹，确认输出仍为照片 + MOV。重启后检查素材的 LIVE 类型保留。导入普通 MOV 后再添加其配对照片与 MOV，应升级原素材且不重复创建现有画格。
5. 把横向 1920×1080、竖向 1080×1920、4:3 三个测试素材分别放入画格；选第一格→自定义，应显示 16:9；改值→重置，应恢复 16:9。依次选第二、第三格，应默认 9:16、4:3，修改后的重置目标也随之切换。
6. 选择空格时重置禁用；选择素材卡片时取该素材比例。检查窄窗口下“添加素材”独占一行，第二行“从照片添加 / 导入文件夹”并列，自定义比例的重置按钮无截断。


## 照片库路径手动验收

必须使用从本 worktree 构建的 App 与嵌套 Helper；二者都带新的读取用途说明、现有 Photos entitlement 和有效签名。直接执行 Swift CLI 测试二进制不能代替 TCC 验收。

1. 初次启动不应主动请求读取权限。点击“从照片添加”，首次使用应出现系统照片读取授权；如果此前仅有“保存到照片”的添加权限，此操作仍需读取授权。允许后显示系统选择器，仅显示 Live Photo。
2. 点击“不允许”：应显示“没有照片读取权限”，提供“打开隐私设置”；关闭提示或改用文件配对不会丢失已有拼贴。点击设置按钮确认跳到照片权限页；手动允许后再次点击入口，应能进入选择器。系统限制场景应提示屏幕使用时间/设备管理，不应循环请求或自动重置权限。
3. 如果系统提供有限照片授权：选择器标题应说明仅可导入已授权照片；选择允许访问的 Live 应可导入，未授权或已移除的资源应显示明确提示和设置入口。实际系统可用的授权模式随 macOS 版本而异。
4. 选择一项本地 Live、以及一项已经编辑过的 Live；应分别新增带 LIVE 标签的完整素材。编辑过的 Live 当前导入未修改原始照片与运动资源，不承诺保留 Photos 内裁剪/滤镜。把素材拖入时间线和多拼画格，调整裁剪、选段并导出到测试文件夹，检查配对输出。
5. 选择一项仅在 iCloud 的 Live：主界面应显示下载提示，完成后能预览/导出。离线、资源缺失或磁盘写入失败应显示错误，不新增只有照片或只有 MOV 的素材；失败批次不应残留半套资源。
6. 系统选择器点击取消、或关闭选择窗口：不新增素材，进度恢复，空批次目录被清理；随后可重新打开，不能出现重复选择窗口。下载和选择共用最长约 2 分钟等待；主界面可点击“取消”，超时会提示重试，Worker 退出后清理本批次资源。
7. 成功导入后重启 App，确认 Live 类型及两个资源路径仍可使用，资源不依赖 Worker 临时响应目录。多选时确认每项都是完整资源；资源导出/校验按批次处理，任一项失败时整批失败。
8. 回归现有文件配对入口和“保存到照片”的 addOnly 流程；此次新增读取授权不能替代或自动重置现有保存授权。

已知边界：每次最多 10 项；iCloud 下载必须联网。照片库成功导入会保留本机副本，当前没有按图库 assetIdentifier 去重，也没有随素材移除自动清理副本；再次导入同一项会产生新副本。原片已导出但前端预览生成失败时，副本仍保留。选择或下载阶段可使用主界面的取消按钮。封面仍使用时间线选帧。

API 依据：[Apple PHPickerViewController](https://developer.apple.com/documentation/photosui/phpickerviewcontroller)、[Apple PHAssetResourceManager](https://developer.apple.com/documentation/photos/phassetresourcemanager)。

## 2026-10-27 卡住修复与回归

- 旧读取授权实现占用 MainActor 循环等待，却将授权回调再派发到主队列，存在无法恢复的等待。实测旧 Worker 获得授权后，线程采样主线程停在 Swift 的 CFRunLoop 而没有进入 AppKit 的 `NSApplication.run()`（`/tmp/lives-photo-worker-sample.txt`），窗口事件依赖缺失；旧选择器还使用阻塞式 `runModal`。修复后 Worker 使用 AppKit 事件循环，授权及选择改为异步等待，关闭或取消返回空选择。原失败截图和当时阶段日志不可用，不能确认上述等待就是那次故障的唯一原因。
- 前端有取消和 2 分钟独立超时，退出时清除 busy/loading；取消通过请求 ID 传到 Helper，终止 Worker 并清理失败批次。Worker 异常退出、启动失败和超时返回 PHOTO 错误。iCloud 下载没有百分比，界面说明等待和时限。
- 阶段诊断写入 `~/Library/Logs/Lives/photo-reset.log`，仅含启动、授权状态、选择数量和错误代码，不记录图库标识和文件路径。检查 `photo-import: worker started`、`authorization status`、`selected count`、`completed` 或 `failed`，以区分启动、授权、选择和导出。
- 回归：点击入口，检查授权/选择器显示；关闭选择器后再次打开；下载中点击主界面取消并确认按钮恢复、该批次无残留；等待超时确认错误提示；分别检查拒绝授权和离线下载；最后选取测试 Live 完成导入并重启验证。真实 TCC、选择器及 iCloud 需要在新 Debug App 上验收。

- 上一轮新包实测：`npm run tauri:dev:app` 成功，App/内嵌 Helper 照片权限签名检查通过，Helper 二进制 SHA-256 与构建产物一致；通过 Helper 协议发起导入，日志记录授权状态为 3、`picker visible=true`，随后发送取消，取消请求返回 result，Worker 退出且测试批次清理。当时取消的导入请求返回 `UNEXPECTED_ERROR`；没有验证系统选择器点击或实际导出。

## 2026-10-27 空态继续排查（未完成自验）

- 关闭旧 App 和 Helper 后，重新构建并启动本 worktree Debug 包。`/tmp/lives-picker-debug-build.log` 记录构建与 App/Helper 权限签名检查成功；Debug 包未公证。照片读取状态为 3（完全授权），PhotoKit 查询到 2,395 项可访问 Live，选择器窗口 `visible=true`。所以不能把现场空态归因于无 Live 或有限授权；`visible=true` 也不能证明系统图库网格加载成功。`.livePhotos` 筛选、系统选择器展开和窗口嵌入之间的具体原因仍未确定。
- 选择器外增加点击“选择照片”的说明；查询无可访问 Live 时给出检查图库或文件配对导入的建议，有限授权时给出系统设置和文件配对建议。文字和嵌入布局尚未通过实际系统窗口截图或点击验证，不能据此认定问题已解决。
- `swift test --package-path native/LivePhotoService --scratch-path /tmp/lives-live-import-helper-build --filter PhotoLibraryImportTests`：7 项通过。主界面取消后等待状态消失、导入按钮恢复；新包 Helper 协议实测取消请求返回 `result: null`，原导入请求返回 `result: []`，没有 `UNEXPECTED_ERROR`，Worker 不再残留。`git diff --check` 通过。
- 阻塞：Computer Use 无权操作 Helper；`System Events` 返回 osascript 不允许辅助访问；`screencapture` 返回 `could not create image from display`。因此尚未证实系统按钮可展开、Live 缩略图可见或能选择并完成导入；有限授权、无 Live 空态及 iCloud 也未在真实系统完成验证。需要可访问系统选择器的本机自动化环境继续复现，不能以用户之后的验收代替这些开发自验。

## 2026-10-27 重新连接后的开发自验（仍未完成）

本节更新并覆盖上一节中对空态原因和 Computer Use 可访问性的未决结论。旧 Helper 窗口只有很小的内容区域；使用 Computer Use 的窗口放大操作后，系统「实况照片」网格和缩略图出现，说明在本机完全授权且有 2,395 项 Live 的条件下，图库已经加载，窗口尺寸是现场空壳的直接因素。系统底部「选择照片」是选择状态区域，上一节的“点击选择照片展开”说明不准确。

调整 `PhotoLibraryImporter.swift`：在设置窗口内容控制器之后恢复 760 × 600 点内容尺寸，并设置 640 × 480 点最小内容尺寸；同步改为在下方图库选择的提示。新构建首次打开后直接显示实况照片网格，无需先放大。Computer Use 截图保存在 `/tmp/lives-picker-grid-verified.jpg`，包含个人图库内容，不纳入仓库。阶段日志 `~/Library/Logs/Lives/photo-reset.log` 记录授权状态 3、可访问 Live 数 2395、窗口可见；截图才是网格显示的证据。有限授权及空图库的真实系统状态仍未验证。

Computer Use 这次可读取 Helper 窗口 AX 和截图，也可操作窗口关闭按钮；但系统图库内部未出现在 Helper 的 AX 树中，坐标单击、双击缩略图及点击系统取消按钮没有可见响应，键盘尝试也未选中项目。不能据此区分自动化输入路由限制与应用内输入问题，也不能认定真人点击有效。未选中 Live，未证明从图库导入成功。选择器关闭返回空选择：日志记录 `selected count=0`、`completed count=0`；主界面等待提示消失、导入按钮恢复，无错误提示。主界面自己的取消按钮也实测恢复了界面。一次等待超时后同样恢复并显示明确的超时提示。

验证：`swift test --package-path native/LivePhotoService --scratch-path /tmp/lives-live-import-helper-build --filter PhotoLibraryImportTests` 7 项通过（`/tmp/lives-picker-swift-retest.log`）。标准 Debug 构建两次因 Apple 时间戳服务不可用失败；为本机验证仅临时通过 PATH 包装 `codesign` 将 `--timestamp` 改为 `--timestamp=none`，保留 Developer ID 签名和原 entitlements，再运行 `npm run tauri:dev:app` 成功（`/tmp/lives-picker-size-build-local.log`）。该包仅供本机 Debug，不证明正常时间戳签名或发布就绪。旧进程已关闭，仅启动本 worktree 最新 Debug 包。

剩余阻塞：必须进一步确认系统选择器内缩略图能实际选中并完成至少一项导入，必要时定位并修复输入问题；之后再验证 iCloud、有限授权和空图库。当前没有 `not approved` 错误，且已经能读取截图和操作 Helper 窗口，因此不能确定需要给某个具体 App 增加系统权限，也不应要求盲目修改权限。


## 2026-10-27 合并文件导入入口

“添加素材”取代原“添加视频”和“添加 Live”按钮，独占原来一行；“从照片添加”和文件夹入口仍独立。首启引导、空项目、素材库帮助以及照片选择器的文件导入指引同步更新。Mac 文件选择器允许混选视频与照片；有照片时先按 ContentIdentifier 查找唯一匹配 MOV，匹配成功后连同其余普通视频复用原有导入流程。照片缺少配对、重复或无效时显示错误并停止整次文件导入；照片不会作为普通素材导入。网页预览仍只支持视频文件。

验证：`npm test` 10 个文件、109 项通过；`npm run build` 通过，保留现有 chunk 大小提示；`swift test --package-path native/LivePhotoService --scratch-path /tmp/lives-live-import-helper-build --filter 'LivePhotoImportTests|PhotoLibraryImportTests'` 12 项通过。新增测试覆盖纯视频、混合文件分流、未配对照片失败、乱序标识匹配与重复标识失败。实际系统文件选择器的混选操作和窄窗口外观尚未人工验证。

照片库自验结论不变：选择器窗口尺寸修复后网格可见，但 Computer Use 未能选中缩略图并完成照片库导入；不能把文件导入测试当作照片库导入验收。

追加验证：合成 Live 原片与无关 MOV 混选，通过 `swift test --package-path native/LivePhotoService --scratch-path /tmp/lives-live-import-helper-build --filter DurationRenderingTests/testExportedPairCanBeRenamedImportedAndRenderedAsLivePhoto`；正确按标识选中配对 MOV 并完成再次渲染。`npm run tauri:dev:app` 在临时无时间戳的本地签名包装器下构建通过，App 与 Helper 照片签名权限检查通过，日志 `/tmp/lives-merged-import-debug-build.log`；该 Debug 包未公证，不代表发行签名通过。
