# Lives 第三方软件声明

Lives 项目自有源码采用 GNU General Public License v3.0（GPL-3.0-only）。第三方组件保持各自许可；历史版本的既有授权不变。品牌规则见 TRADEMARKS.md。

| 组件 | 版本 | 许可 | 项目 |
| --- | --- | --- | --- |
| React / React DOM | 19.2.7 | MIT | https://github.com/facebook/react |
| Tauri JavaScript API | 2.11.1 | MIT / Apache-2.0 | https://github.com/tauri-apps/tauri |
| Tauri | 2.11.5 | MIT / Apache-2.0 | https://github.com/tauri-apps/tauri |
| Tauri Dialog Plugin | 2.7.2 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Tauri Shell Plugin | 2.3.5 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| Tauri Opener Plugin | 2.5.4 | MIT / Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |
| scheduler | 0.27.0 | MIT | https://github.com/facebook/react/tree/main/packages/scheduler |
| Serde | 1.0.229 | MIT / Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.150 | MIT / Apache-2.0 | https://github.com/serde-rs/json |
| FFmpeg | 8.1.2 | LGPL-2.1-or-later | https://ffmpeg.org |

构建时使用的完整依赖版本由 `package-lock.json`、`src-tauri/Cargo.lock` 和 Swift Package 清单固定。本文件是人工维护的高优先级义务摘要，**不是完整的逐包许可报告**。每次对外发布前，`npm run tauri:build` 会针对当次锁文件强制运行 `cargo-about` 与 npm 生产依赖盘点，生成 `RUST_THIRD_PARTY_LICENSES.html` 和 `NPM_THIRD_PARTY_LICENSES.html`。两份报告未经人工审核并随安装包分发时，不得发布。Swift 代码与仓库内 LivesCore 当前均为自研实现，采用 GPL-3.0-only，不包含第三方开源依赖或第三方字体；引入新 Swift 依赖时必须扩展自动盘点。

## MPL-2.0 组件

`src-tauri/Cargo.lock` 当前锁定以下 MPL-2.0 组件：

| 组件 | 版本 | 许可 |
| --- | --- | --- |
| cssparser | 0.36.0 | MPL-2.0 |
| cssparser-macros | 0.6.1 | MPL-2.0 |
| dtoa-short | 0.3.5 | MPL-2.0 |
| option-ext | 0.2.0 | MPL-2.0 |
| selectors | 0.36.1 | MPL-2.0 |

正式分发包必须保留这些组件的完整 MPL-2.0 文本、版权声明和由许可要求的源文件获取信息；详细范围以当次自动生成并经审核的逐包报告为准。MPL-2.0 完整条款见：https://www.mozilla.org/MPL/2.0/

## BSD-3-Clause 义务

`src-tauri/Cargo.lock` 当前锁定以下包含 BSD-3-Clause 许可选项或义务的组件：

| 组件 | 版本 | Cargo 元数据中的许可表达式 |
| --- | --- | --- |
| encoding_rs | 0.8.35 | (Apache-2.0 OR MIT) AND BSD-3-Clause |
| alloc-no-stdlib | 2.0.4 | BSD-3-Clause |
| alloc-stdlib | 0.2.4 | BSD-3-Clause |
| brotli | 8.0.4 | BSD-3-Clause AND MIT |
| brotli-decompressor | 5.0.3 | BSD-3-Clause / MIT |

二进制再分发时必须保留上游版权声明、条件和免责声明。具体原文不在本摘要中重复，必须由当次完整逐包许可报告携带。

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
