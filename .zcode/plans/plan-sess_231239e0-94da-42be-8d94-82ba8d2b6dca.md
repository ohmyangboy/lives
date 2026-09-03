# 拼贴自定义画布比例

## 目标
右侧「拼贴设置 → 画面比例」在现有 5 个预设比例后新增「自定义」选项，可自由输入宽:高，预览与导出画布即时跟随。

## 现状与关键结论
- 比例定义在 `src/domain.ts:2`（`AspectRatioId` 联合类型）+ L19-25（预设表），`canvasDimensions`（L27-33）按「短边 = 画质（1080p→1080 / 720p→720），长边按比例」算像素。
- Swift sidecar 渲染端只接收像素宽高；`TemplateLayout.swift` 用归一化坐标布局，天然支持任意比例，**无需改动**。
- 唯一硬阻碍：`LivePhotoPipeline.swift:29-35` `supportsCanvas` 硬编码 10 个尺寸白名单，需放宽为规则校验。

## 改动清单

### 1. `src/domain.ts`（领域层）
- `AspectRatioId` 增加 `'custom'`；`CanvasSettings` 增加可选 `customRatio?: { width: number; height: number }`。
- 新增导出：`CUSTOM_RATIO_BOUNDS`（比例限制 1:3 – 3:1，防止极端比例超出 H.264 编码安全范围）和 `normalizeCustomRatio()`（取正整数、按边界夹紧比例并保持整数）。
- `canvasDimensions`：`aspectRatio === 'custom'` 时用 `customRatio`（未提供则回退 9:16）；长边 = `round(短边 × 长比/短比)` 并强制偶数（H.264 要求宽高为偶数）；预设路径逻辑不变。

### 2. `src/App.tsx`（状态 + UI）
- 新增 `customRatio` state（默认 9:16）。
- L293 画布计算、L771 附近 `createRenderProject` 的 canvasSettings、L1039 `ExportDestinationPicker` 调用均带上 `customRatio`。
- L994「场景比例」行：预设 chips 后追加「自定义」按钮（横竖屏下都显示）；选中时其下新增一行「自定义比例」编辑器：宽/高两个数字输入框 + 宽高交换按钮，small 文案实时显示导出像素「1080 × 2520」。
- 点击「自定义」时用当前预设的宽高预填输入框；onChange 取整，blur 时夹紧写回。
- `changeCanvasOrientation`（L821-827）：当前为 custom 时交换宽高；画布方向 segmented 的选中态在 custom 下按实际宽高派生，避免与画布矛盾。

### 3. `src/components/ExportDestinationPicker.tsx`
- Props 增加 `customRatio`，L25-26 两处 `canvasDimensions` 传入，导出弹窗的 1080P/720P 像素预览随自定义比例联动。

### 4. `src/styles.css`
- 为自定义比例编辑器新增紧凑样式，匹配现有 `.setting-row` / `.segmented` 风格。

### 5. `native/.../LivePhotoPipeline.swift`（必改）
- `supportsCanvas` 白名单改为规则校验：短边 ∈ {720, 1080}（沿用画质策略）、长边 ≤ 3240（3:1 上限）、宽高均为偶数。原 10 个预设尺寸全部仍通过。

### 6. 测试
- `src/domain.test.ts`：新增 custom 用例（5:7@720p → 720×1008；超界夹紧到 1:3；奇数长边偶数化；缺 customRatio 回退 9:16）。
- `TemplateLayoutTests.swift` 的 `testSupportedCanvasSizesCoverEveryEditorRatioAndQuality`（L26-38）：预设 10 尺寸仍通过；新增 custom 尺寸通过（如 1080×2160、720×1008）；拒绝奇数（1080×1697）、超上限（1080×4320）、短边不符（640×480）。

### 无需改动
`CollagePreview.tsx`（已接收数值宽高）、`nativeBridge.ts`（透传）、`src-tauri/`（不参与）、`TemplateLayout.swift`（归一化自适应）。

## 验证
- `npm test` + TypeScript 构建通过；
- `swift test`（native/LivePhotoService）通过；
- 手动验证：选自定义 → 输入 5:7 → 预览与导出弹窗尺寸联动 → 导出成功。