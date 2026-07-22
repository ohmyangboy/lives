# Lives 0.1.2

适用于 Apple Silicon Mac，要求 macOS 13 Ventura 或更高的正式版本。

## 本次修复

- 支持导入由 Live Photo 转换得到、时长接近 3 秒的视频。
- 2.5～3 秒的素材会使用最后一帧平滑补齐到 3 秒，不再被误判为无法读取。
- 有声音的短素材只保留原始音频，补齐部分保持静音，避免声音循环或拉伸。
- 时间线会明确标识原始时长与补帧部分。
- 导入失败时显示具体文件和实际时长。

## 安装前请了解

此版本使用 ad-hoc 签名，尚未经过 Apple Developer ID 签名或 Apple 公证，也没有应用内自动更新。请只从官方 Release 下载并核对 SHA-256。

## 文件校验

`Lives_0.1.2_aarch64.dmg`

`2e7ab431ff4ab69edfb356ab40936c60151abaa422b49a3e93d6cd4f3fdc45e6`
