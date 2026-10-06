# Mac 胶卷与观片器模型

`LivesFilm.usdz` 与 `PreviewLoupe.usdz` 按用户在本次 Mac 编辑器开发中的明确要求，直接复用 Lives Mobile 的现有模型，未重新生成或修改二进制内容。

来源按用户指定的原文件核对：

- 观片器：`lives-mobile/LivesMobile/Sources/Models/PreviewLoupe.usdz`。
- 胶卷：`area/Lives Mobile App Store/v1.0.0/videos/lives-promo-final-v15/src-en/models/LivesFilm.usdz`（与 Mobile 模型加入提交 `e782e0a` 中的同名文件一致）。

USD 内元数据记录胶卷为根据提供的 Lives 插画制作，观片器为参照外观重建，非 Apple 官方资产。品牌使用遵循根目录 `TRADEMARKS.md`；这次资源复用不修改 Mobile 仓库的源码许可。

两份 USDZ 内含 USDA 几何、材质与 PNG 贴图，无外部资源 URL。Mac 从本仓库加载这些资源，不在运行或构建时依赖相邻仓库。读取时只在内存中将行内数组属性改为 Three USD 读取器支持的多行格式，保留原始几何、材质、UV 数值和贴图；保存及构建输出的 USDZ 字节不变。运行时参照 Mobile 设置相机、环境光、炭黑漆面与观片器玻璃透明度。换卷只移动视频条，胶卷模型保持在原位。WebGL 只在模型加载、姿态改变和容器尺寸改变时重绘。

复制校验 SHA-256：

| 资源 | SHA-256 |
| --- | --- |
| `LivesFilm.usdz` | `baf1a277cd3193033ee950103885af51a1ed9580c060845a8df81a9a160d112b` |
| `PreviewLoupe.usdz` | `77e4f1171b3f80c45db8078bd54a2157f3ed518cb8719e7a39b85e490d52e837` |

日常开发和生产构建直接使用保存的 USDZ。
