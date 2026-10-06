# Lives 许可边界

> 2026-09-15：本仓库的项目自有代码统一采用
> GNU General Public License v3.0（GPL-3.0-only）。历史公开版本的既有授权不撤回。

## 当前状态

- 根目录 [LICENSE](LICENSE) 是 GNU GPL v3 全文，既是本仓库当前对外的许可文本，也覆盖历史公开版本。
- `packages/LivesCore` 为本仓库内部模块，随本仓库按同一许可提供；历史公开版本中的旧 `native/LivesCore` 源码与相应 GPL 授权同样保留。
- 第三方软件、字体与素材继续适用各自许可，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 本文件不授予任何新许可，也不改变既有授权。

## 0.1.15 分发核对

本次官方发行的源码、品牌资源与用户提供的二维码来源依据见 [0.1.15 发布来源核对](docs/releases/0.1.15-source-check.md)。第三方组件仍按原许可分发完整声明及所需对应源码；本记录不授予额外的品牌许可。

当前许可表达为 `GPL-3.0-only`。将来若改为 `GPL-3.0-or-later`，需同步 `package.json`、`website/package.json`、`src-tauri/Cargo.toml` 与 `scripts/release_preflight.py` 的校验值，并重新核对相应授权。
