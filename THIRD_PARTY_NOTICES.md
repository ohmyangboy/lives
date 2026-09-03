# Lives 第三方软件声明

Lives 0.1.2 包含或依赖以下主要开源组件。Lives 应用源代码基于 [GNU General Public License v3.0](LICENSE) 开源；Lives 品牌素材仍归 Copyright © 2026 ohmyangboy 所有，除第三方许可另有规定外保留所有权利。

| 组件 | 版本 | 许可 | 项目 |
| --- | --- | --- | --- |
| React / React DOM | 19.2.7 | MIT | https://github.com/facebook/react |
| Tauri JavaScript API | 2.11.1 | MIT / Apache-2.0 | https://github.com/tauri-apps/tauri |
| Tauri | 2.11.5 | MIT / Apache-2.0 | https://github.com/tauri-apps/tauri |
| Tauri Dialog Plugin | 2.7.2 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Tauri Shell Plugin | 2.3.5 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Tauri Opener Plugin | 2.5.4 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Serde | 1.0.229 | MIT / Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.150 | MIT / Apache-2.0 | https://github.com/serde-rs/json |
| FFmpeg | 8.1.2 | LGPL-2.1-or-later | https://ffmpeg.org |

构建时使用的完整依赖版本由 `package-lock.json`、`src-tauri/Cargo.lock` 和 Swift Package 清单固定。后续加入或升级依赖时，应同步更新本文件并复核其再分发条件。

## FFmpeg

Lives 使用动态链接的精简 FFmpeg 运行时，仅在 macOS 无法直接解码视频时，将用户选中的片段转换为本地临时兼容格式。该构建未启用 GPL 或 nonfree 组件。应用安装包内包含 LGPL 2.1 许可文本和完整构建配置。

- 完整构建配置：`vendor/ffmpeg/BUILD-CONFIGURATION.txt`
- LGPL 2.1 许可：`vendor/ffmpeg/licenses/COPYING.LGPLv2.1`
- 对应源代码：https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz
- 源代码 SHA-256：`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`

## MIT License

Copyright notices belong to the respective upstream authors and contributors.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Apache-2.0 的完整条款见：https://www.apache.org/licenses/LICENSE-2.0
