# Lives 许可边界

> 2026-09-15：本仓库的项目自有代码统一采用
> GNU General Public License v3.0（GPL-3.0-only）。历史公开版本的既有授权不撤回。

## 当前状态

- 根目录 [LICENSE](LICENSE) 是 GNU GPL v3 全文，既是本仓库当前对外的许可文本，也覆盖历史公开版本。
- `packages/LivesCore` 为本仓库内部模块，随本仓库按同一许可提供；历史公开版本中的旧 `native/LivesCore` 源码与相应 GPL 授权同样保留。
- 第三方软件、字体与素材继续适用各自许可，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 本文件不授予任何新许可，也不改变既有授权。

## 待办（对外发布前必须完成）

1. **权属范围**：核对自有代码、外部贡献与历史迁移代码的权利覆盖，保留可核验记录。
2. **品牌资源**：`packages/LivesCore/Sources/LivesCore/Resources/WatermarkAppIcon.png`
   的对外可分发性需单独确认；不能以删除资源代替运行时验证。
3. **许可表达复核**：当前采用 `GPL-3.0-only`。若改为 `GPL-3.0-or-later`，需同步
   `package.json`、`website/package.json`、`src-tauri/Cargo.toml` 与 `scripts/release_preflight.py` 的校验值。
